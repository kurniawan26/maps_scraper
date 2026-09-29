import { chromium } from 'playwright';

const LAUNCH_ARGS = [
  '--no-sandbox',
  '--disable-dev-shm-usage',
  '--disable-blink-features=AutomationControlled',
  '--lang=id-ID'
];

const CONSENT_COOKIE = {
  name: 'SOCS',
  value: 'CAESHAgBEhJnd3NfMjAyNDA5MTAtMF9SQzIaAmVuIAEaBgiAm7y3Bg',
  domain: '.google.com',
  path: '/'
};

const PIXEL = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');

const WS_ENDPOINT = process.env.PLAYWRIGHT_WS_ENDPOINT || '';
const CDP_ENDPOINT = process.env.PLAYWRIGHT_CDP_ENDPOINT || '';

export function browserMode() {
  if (WS_ENDPOINT) return { mode: 'connect', endpoint: WS_ENDPOINT };
  if (CDP_ENDPOINT) return { mode: 'connect_over_cdp', endpoint: CDP_ENDPOINT };
  return { mode: 'launch', endpoint: null };
}

function openBrowser() {
  if (WS_ENDPOINT) return chromium.connect(WS_ENDPOINT, { timeout: 30_000 });
  if (CDP_ENDPOINT) return chromium.connectOverCDP(CDP_ENDPOINT, { timeout: 30_000 });
  return chromium.launch({ headless: true, args: LAUNCH_ARGS });
}

const IDLE_TIMEOUT_MS = toInt(process.env.BROWSER_IDLE_TIMEOUT_MS, 300_000);
const MAX_CONTEXTS = toInt(process.env.BROWSER_MAX_CONTEXTS, 200);

function toInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

let browserPromise = null;
let activeContexts = 0;
let contextsServed = 0;
let retiring = false;
let idleTimer = null;

function clearIdleTimer() {
  if (idleTimer) {
    clearTimeout(idleTimer);
    idleTimer = null;
  }
}

function retireBrowser(reason) {
  const retired = browserPromise;

  browserPromise = null;
  contextsServed = 0;
  retiring = false;
  clearIdleTimer();

  if (!retired) return;

  console.log(`[scraper] menutup browser (${reason})`);
  retired.then((browser) => browser.close().catch(() => { })).catch(() => { });
}

function scheduleIdleShutdown() {
  if (IDLE_TIMEOUT_MS === 0) return;

  clearIdleTimer();
  idleTimer = setTimeout(() => {
    if (activeContexts === 0) retireBrowser(`idle ${IDLE_TIMEOUT_MS} ms`);
  }, IDLE_TIMEOUT_MS);

  idleTimer.unref?.();
}

function launchBrowser() {
  const promise = openBrowser().then((browser) => {
    browser.on('disconnected', () => {
      if (browserPromise !== promise) return;

      browserPromise = null;
      contextsServed = 0;
      retiring = false;
      clearIdleTimer();
    });

    return browser;
  });

  return promise;
}

export async function getBrowser() {
  if (!browserPromise) browserPromise = launchBrowser();

  try {
    return await browserPromise;
  } catch (error) {
    browserPromise = null;
    throw error;
  }
}

async function acquireBrowser() {
  clearIdleTimer();

  if (retiring && activeContexts === 0) retireBrowser(`kuota ${MAX_CONTEXTS} context`);

  const browser = await getBrowser();

  activeContexts += 1;
  contextsServed += 1;
  if (MAX_CONTEXTS > 0 && contextsServed >= MAX_CONTEXTS) retiring = true;

  return browser;
}

function releaseBrowser() {
  activeContexts = Math.max(0, activeContexts - 1);
  if (activeContexts > 0) return;

  if (retiring) {
    retireBrowser(`kuota ${MAX_CONTEXTS} context`);
    return;
  }

  scheduleIdleShutdown();
}

export function browserStats() {
  return {
    running: browserPromise !== null,
    active_contexts: activeContexts,
    contexts_served: contextsServed,
    idle_timeout_ms: IDLE_TIMEOUT_MS,
    max_contexts: MAX_CONTEXTS,
    retiring
  };
}

const NOTHING_READ = Symbol('belum terbaca');

function navigationRace(error) {
  return /Execution context was destroyed|context was destroyed|frame was detached|Target closed/i.test(
    error?.message || ''
  );
}

export async function extractWhenStable(page, extractor, { rounds = 6, interval = 400 } = {}) {
  let previous = null;
  let latest = NOTHING_READ;
  let lastError = null;

  for (let round = 0; round < rounds; round += 1) {
    let current;

    try {
      current = await page.evaluate(extractor);
    } catch (error) {
      if (!navigationRace(error)) throw error;

      lastError = error;
      previous = null;
      await page.waitForTimeout(interval);
      continue;
    }

    lastError = null;
    latest = current;

    const serialized = JSON.stringify(current);
    if (serialized === previous) return current;

    previous = serialized;
    await page.waitForTimeout(interval);
  }

  if (latest === NOTHING_READ) throw lastError ?? new Error('Halaman tidak dapat dibaca');

  return latest;
}

export async function withPage(options, callback) {
  const {
    lang = 'id',
    country = 'ID',
    timeout = 45000,
    blockAssets = true,
    handleRequest = null
  } = options;
  const browser = await acquireBrowser();
  let context = null;

  try {
    context = await browser.newContext({
      locale: `${lang}-${country}`,
      timezoneId: process.env.TZ || 'Asia/Jakarta',
      viewport: { width: 1440, height: 900 },
      userAgent:
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
      extraHTTPHeaders: { 'Accept-Language': `${lang}-${country},${lang};q=0.9` }
    });

    await context.addCookies([CONSENT_COOKIE]);
    context.setDefaultTimeout(timeout);
    context.setDefaultNavigationTimeout(timeout);

    if (blockAssets || handleRequest) {
      await context.route('**/*', async (route) => {
        const request = route.request();
        const type = request.resourceType();

        if (blockAssets) {
          if (type === 'image') {
            return route.fulfill({ status: 200, contentType: 'image/gif', body: PIXEL });
          }
          if (type === 'media' || type === 'font') return route.abort();
        }

        if (handleRequest) {
          try {
            return await handleRequest(route, request);
          } catch {
            return route.abort('failed');
          }
        }

        return route.continue();
      });
    }

    const page = await context.newPage();
    await dismissConsent(page);
    return await callback(page);
  } finally {
    if (context) await context.close().catch(() => { });
    releaseBrowser();
  }
}

export async function dismissConsent(page) {
  page.on('framenavigated', async (frame) => {
    if (frame !== page.mainFrame()) return;
    if (!/consent\.google\./.test(frame.url())) return;

    const button = page
      .locator('button[aria-label*="Accept"], button[aria-label*="Setuju"], form button')
      .first();
    await button.click({ timeout: 5000 }).catch(() => { });
  });
}

export async function closeBrowser() {
  clearIdleTimer();

  const pending = browserPromise;
  browserPromise = null;
  contextsServed = 0;
  retiring = false;

  if (!pending) return;

  const browser = await pending.catch(() => null);
  if (browser) await browser.close().catch(() => { });
}
