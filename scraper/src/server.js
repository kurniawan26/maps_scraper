import http from 'node:http';
import { browserMode, browserStats, closeBrowser } from './browser.js';
import { ScrapeError, scrapePlace, scrapeSearch } from './maps.js';
import { clampInt, isMapsUrl } from './util.js';

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

function buildOptions(payload) {
  return {
    lang: typeof payload.lang === 'string' ? payload.lang : 'id',
    country: typeof payload.country === 'string' ? payload.country : 'ID',
    limit: payload.limit,
    detail: payload.detail === true,
    timeout: clampInt(payload.timeout, { min: 5000, max: 120000, fallback: 45000 })
  };
}

async function handleScrape(req, res) {
  if (MAX_CONCURRENT_SCRAPES > 0 && inFlight >= MAX_CONCURRENT_SCRAPES) {
    throw new ScrapeError(`Sidecar sedang menangani ${inFlight} permintaan`, {
      status: 503,
      code: 'busy'
    });
  }

  const payload = await readBody(req);
  const query = typeof payload.query === 'string' ? payload.query.trim() : '';

  if (!query) {
    throw new ScrapeError('Field "query" wajib diisi', { status: 422, code: 'missing_query' });
  }

  const options = buildOptions(payload);

  inFlight += 1;
  try {
    const result = isMapsUrl(query)
      ? await scrapePlace(query, options)
      : await scrapeSearch(query, options);

    sendJson(res, 200, result);
  } finally {
    inFlight -= 1;
  }
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
