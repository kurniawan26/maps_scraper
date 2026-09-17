import http from 'node:http';
import { browserMode, closeBrowser } from './browser.js';
import { ScrapeError, scrapePlace, scrapeSearch } from './maps.js';
import { clampInt, isMapsUrl } from './util.js';

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || '0.0.0.0';
const MAX_BODY_BYTES = 64 * 1024;

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body)
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
  const payload = await readBody(req);
  const query = typeof payload.query === 'string' ? payload.query.trim() : '';

  if (!query) {
    throw new ScrapeError('Field "query" wajib diisi', { status: 422, code: 'missing_query' });
  }

  const options = buildOptions(payload);
  const result = isMapsUrl(query)
    ? await scrapePlace(query, options)
    : await scrapeSearch(query, options);

  sendJson(res, 200, result);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  try {
    if (req.method === 'GET' && url.pathname === '/health') {
      return sendJson(res, 200, {
        status: 'ok',
        uptime: Math.round(process.uptime()),
        browser: browserMode()
      });
    }

    if (req.method === 'POST' && url.pathname === '/scrape') {
      return await handleScrape(req, res);
    }

    return sendJson(res, 404, { error: { code: 'not_found', message: 'Endpoint tidak dikenal' } });
  } catch (error) {
    const status = error instanceof ScrapeError ? error.status : 500;
    const code = error instanceof ScrapeError ? error.code : 'internal_error';

    if (status >= 500) console.error('[scraper]', error);
    if (res.headersSent) return res.end();

    return sendJson(res, status, { error: { code, message: error.message } });
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
    server.close(async () => {
      await closeBrowser();
      process.exit(0);
    });
  });
}
