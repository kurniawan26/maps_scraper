import http from 'node:http';
import { browserMode, browserStats, closeBrowser } from './browser.js';
import { scrapeProfile } from './instagram.js';
import { scrapeMarketplace } from './marketplace.js';
import { scrapeTiktok } from './tiktok.js';
import { scrapePlace, scrapeSearch } from './maps.js';
import { scrapeWebsite } from './website.js';
import {
  ScrapeError,
  clampInt,
  instagramUsername,
  isMapsUrl,
  marketplaceStore,
  tiktokUsername,
  websiteUrl
} from './util.js';

function toInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || '0.0.0.0';
const MAX_BODY_BYTES = 64 * 1024;

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

function buildInstagramOptions(payload) {
  return {
    lang: typeof payload.lang === 'string' ? payload.lang : 'en',
    country: typeof payload.country === 'string' ? payload.country : 'US',
    name: typeof payload.name === 'string' && payload.name.trim() ? payload.name.trim() : null,
    timeout: buildTimeout(payload)
  };
}

function buildWebsiteOptions(payload) {
  return {
    lang: typeof payload.lang === 'string' ? payload.lang : 'id',
    country: typeof payload.country === 'string' ? payload.country : 'ID',
    name: typeof payload.name === 'string' && payload.name.trim() ? payload.name.trim() : null,
    timeout: buildTimeout(payload)
  };
}

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

async function handleTiktok(req, res) {
  const { payload, query } = await readQuery(req);
  const username = tiktokUsername(query);

  if (!username) {
    throw new ScrapeError('Query bukan username maupun URL profil TikTok', {
      status: 422,
      code: 'invalid_username'
    });
  }

  const options = { ...buildInstagramOptions(payload), query };
  const result = await withSlot(() => scrapeTiktok(username, options));

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

    if (req.method === 'POST' && url.pathname === '/scrape/tiktok') {
      return await handleTiktok(req, res);
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

    if (status >= 500 && code !== 'busy') console.error('[scraper]', error);
    if (res.headersSent) return res.end();

    const headers = code === 'busy' ? { 'retry-after': '5' } : {};

    return sendJson(res, status, { error: { code, message: error.message } }, headers);
  }
});

server.requestTimeout = 180000;
server.headersTimeout = 185000;

server.listen(PORT, HOST, () => {
  console.log(`[scraper] mendengarkan di http://${HOST}:${PORT}`);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
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
