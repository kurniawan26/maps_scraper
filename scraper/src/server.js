import http from 'node:http';
import { browserMode, browserStats, closeBrowser } from './browser.js';
import { scrapeProfile } from './instagram.js';
import { scrapeMarketplace } from './marketplace.js';
import { scrapePlace, scrapeSearch } from './maps.js';
import { scrapeWebsite } from './website.js';
import {
  ScrapeError,
  clampInt,
  instagramUsername,
  isMapsUrl,
  marketplaceStore,
  websiteUrl
} from './util.js';

function toInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || '0.0.0.0';
const MAX_BODY_BYTES = 64 * 1024;

// Satu /scrape memakai minimal satu context browser, dan dengan detail=true
// beberapa sekaligus. Tanpa batas, permintaan yang datang bersamaan bisa
// menghabiskan memori container. Yang kelebihan ditolak 503 supaya pemanggil
// mengulang lewat backoff-nya, bukan menunggu di antrean yang tak terlihat.
// Isi 0 untuk mematikan pembatasan.
const MAX_CONCURRENT_SCRAPES = toInt(process.env.MAX_CONCURRENT_SCRAPES, 4);
const SHUTDOWN_GRACE_MS = toInt(process.env.SHUTDOWN_GRACE_MS, 10_000);

let inFlight = 0;

function sendJson(res, status, payload, headers = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    ...headers
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;

    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new ScrapeError('Body terlalu besar', { status: 413, code: 'body_too_large' }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new ScrapeError('Body bukan JSON yang valid', { status: 400, code: 'invalid_json' }));
      }
    });
    req.on('error', reject);
  });
}

function buildTimeout(payload) {
  return clampInt(payload.timeout, { min: 5000, max: 120000, fallback: 45000 });
}

function buildOptions(payload) {
  return {
    lang: typeof payload.lang === 'string' ? payload.lang : 'id',
    country: typeof payload.country === 'string' ? payload.country : 'ID',
    limit: payload.limit,
    detail: payload.detail === true,
    name: typeof payload.name === 'string' && payload.name.trim() ? payload.name.trim() : null,
    timeout: buildTimeout(payload)
  };
}

// Instagram defaultnya en/US, bukan id/ID seperti Maps: seluruh penanda yang
// dibaca instagram.js — "Followers", "Profile isn't available", label "Verified"
// — ikut berubah mengikuti bahasa. Mengunci bahasanya membuat parsing pasti.
function buildInstagramOptions(payload) {
  return {
    lang: typeof payload.lang === 'string' ? payload.lang : 'en',
    country: typeof payload.country === 'string' ? payload.country : 'US',
    name: typeof payload.name === 'string' && payload.name.trim() ? payload.name.trim() : null,
    timeout: buildTimeout(payload)
  };
}

// Sumber "website" membuka URL yang ditentukan pemanggil, jadi bahasanya
// mengikuti Maps (id/ID) — bukan dikunci en/US seperti Instagram, yang penanda
// halamannya memang perlu dipastikan.
function buildWebsiteOptions(payload) {
  return {
    lang: typeof payload.lang === 'string' ? payload.lang : 'id',
    country: typeof payload.country === 'string' ? payload.country : 'ID',
    name: typeof payload.name === 'string' && payload.name.trim() ? payload.name.trim() : null,
    timeout: buildTimeout(payload)
  };
}

// Satu permintaan memakai minimal satu context browser. Slot dihitung di satu
// tempat supaya tiap endpoint baru ikut terbatasi tanpa menyalin penjagaannya.
async function withSlot(handler) {
  if (MAX_CONCURRENT_SCRAPES > 0 && inFlight >= MAX_CONCURRENT_SCRAPES) {
    throw new ScrapeError(`Sidecar sedang menangani ${inFlight} permintaan`, {
      status: 503,
      code: 'busy'
    });
  }

  inFlight += 1;
  try {
    return await handler();
  } finally {
    inFlight -= 1;
  }
}

async function readQuery(req) {
  const payload = await readBody(req);
  const query = typeof payload.query === 'string' ? payload.query.trim() : '';

  if (!query) {
    throw new ScrapeError('Field "query" wajib diisi', { status: 422, code: 'missing_query' });
  }

  return { payload, query };
}

async function handleScrape(req, res) {
  const { payload, query } = await readQuery(req);
  const options = buildOptions(payload);

  const result = await withSlot(() =>
    isMapsUrl(query) ? scrapePlace(query, options) : scrapeSearch(query, options)
  );

  sendJson(res, 200, result);
}

async function handleInstagram(req, res) {
  const { payload, query } = await readQuery(req);
  const username = instagramUsername(query);

  if (!username) {
    throw new ScrapeError('Query bukan username maupun URL profil Instagram', {
      status: 422,
      code: 'invalid_username'
    });
  }

  const options = { ...buildInstagramOptions(payload), query };
  const result = await withSlot(() => scrapeProfile(username, options));

  sendJson(res, 200, result);
}

async function handleMarketplace(req, res) {
  const { payload, query } = await readQuery(req);
  const store = marketplaceStore(query);

  if (!store) {
    throw new ScrapeError('Query bukan URL toko Tokopedia maupun Shopee', {
      status: 422,
      code: 'invalid_store_url'
    });
  }

  const options = { ...buildWebsiteOptions(payload), query };

  // Tokopedia dibaca lewat HTTP polos tanpa context browser sama sekali, jadi
  // tidak perlu memakai slot — yang dijaga slot adalah memori Chromium.
  const result =
    store.platform === 'tokopedia'
      ? await scrapeMarketplace(store, options)
      : await withSlot(() => scrapeMarketplace(store, options));

  sendJson(res, 200, result);
}

async function handleWebsite(req, res) {
  const { payload, query } = await readQuery(req);
  const target = websiteUrl(query);

  if (!target) {
    throw new ScrapeError('Query bukan URL maupun nama domain yang sah', {
      status: 422,
      code: 'invalid_url'
    });
  }

  const options = {
    ...buildWebsiteOptions(payload),
    query,
    // Domain telanjang dinaikkan ke https; kalau gagal, boleh dicoba http.
    // URL yang skemanya ditulis pemanggil dihormati apa adanya.
    httpFallback: !/^[a-z][a-z0-9+.-]*:\/\//i.test(query.trim())
  };

  const result = await withSlot(() => scrapeWebsite(target, options));

  sendJson(res, 200, result);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  try {
    if (req.method === 'GET' && url.pathname === '/health') {
      return sendJson(res, 200, {
        status: 'ok',
        uptime: Math.round(process.uptime()),
        scrapes: { in_flight: inFlight, max_concurrent: MAX_CONCURRENT_SCRAPES },
        browser: { ...browserMode(), ...browserStats() }
      });
    }

    if (req.method === 'POST' && url.pathname === '/scrape') {
      return await handleScrape(req, res);
    }

    if (req.method === 'POST' && url.pathname === '/scrape/instagram') {
      return await handleInstagram(req, res);
    }

    if (req.method === 'POST' && url.pathname === '/scrape/website') {
      return await handleWebsite(req, res);
    }

    if (req.method === 'POST' && url.pathname === '/scrape/marketplace') {
      return await handleMarketplace(req, res);
    }

    return sendJson(res, 404, { error: { code: 'not_found', message: 'Endpoint tidak dikenal' } });
  } catch (error) {
    const status = error instanceof ScrapeError ? error.status : 500;
    const code = error instanceof ScrapeError ? error.code : 'internal_error';

    // 503 karena penuh adalah keadaan normal di bawah beban, bukan kerusakan.
    if (status >= 500 && code !== 'busy') console.error('[scraper]', error);
    if (res.headersSent) return res.end();

    const headers = code === 'busy' ? { 'retry-after': '5' } : {};

    return sendJson(res, status, { error: { code, message: error.message } }, headers);
  }
});

// Scraping bisa lama; jangan diputus lebih cepat dari timeout Playwright.
server.requestTimeout = 180000;
server.headersTimeout = 185000;

server.listen(PORT, HOST, () => {
  console.log(`[scraper] mendengarkan di http://${HOST}:${PORT}`);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    // server.close() menunggu seluruh koneksi selesai. Koneksi keep-alive dari
    // pemanggil bisa menahannya sampai Docker mengirim SIGKILL, dan closeBrowser()
    // tidak pernah sempat jalan. Batas waktu di bawah ini memastikan proses tetap
    // berhenti dengan browser yang sudah ditutup.
    const forced = setTimeout(() => {
      console.warn(`[scraper] berhenti paksa setelah ${SHUTDOWN_GRACE_MS} ms`);
      closeBrowser().finally(() => process.exit(1));
    }, SHUTDOWN_GRACE_MS);
    forced.unref?.();

    server.closeIdleConnections?.();
    server.close(async () => {
      clearTimeout(forced);
      await closeBrowser();
      process.exit(0);
    });
  });
}
