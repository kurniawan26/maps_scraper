import { chromium } from 'playwright';

const LAUNCH_ARGS = [
  '--no-sandbox',
  '--disable-dev-shm-usage',
  '--disable-blink-features=AutomationControlled',
  '--lang=id-ID'
];

// Cookie persetujuan Google. Tanpa ini sebagian region berhenti di halaman consent.
const CONSENT_COOKIE = {
  name: 'SOCS',
  value: 'CAESHAgBEhJnd3NfMjAyNDA5MTAtMF9SQzIaAmVuIAEaBgiAm7y3Bg',
  domain: '.google.com',
  path: '/'
};

// GIF transparan 1x1 sebagai pengganti setiap gambar.
const PIXEL = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');

// Tiga cara mendapatkan browser, dipilih lewat environment:
//
//   (kosong)                  -> launch Chromium sendiri dari image ini (default)
//   PLAYWRIGHT_WS_ENDPOINT    -> pakai Playwright server yang sudah ada di host
//                                (`npx playwright run-server`), versi harus sama
//   PLAYWRIGHT_CDP_ENDPOINT   -> sambung ke Chrome/Chromium yang sudah berjalan
//                                dengan --remote-debugging-port
//
// Dua mode terakhir membuat sidecar ini tidak lagi membawa browsernya sendiri,
// sehingga bisa ditempatkan di server yang Playwright-nya sudah tertanam.
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

// --- Daur hidup browser --------------------------------------------------
//
// Browser tidak dinyalakan saat proses start, melainkan saat context pertama
// dibutuhkan, lalu dipakai ulang. Dua mekanisme menjaganya tidak hidup selamanya:
//
//   BROWSER_IDLE_TIMEOUT_MS  tutup browser setelah sekian lama tidak dipakai
//   BROWSER_MAX_CONTEXTS     tutup dan nyalakan ulang setelah sekian context
//
// Isi 0 untuk mematikan salah satunya. Keduanya hanya menutup browser ketika
// tidak ada context yang sedang berjalan, jadi tidak pernah memotong scraping
// yang belum selesai.
//
// Catatan satuan: yang dihitung adalah context, bukan permintaan HTTP. Satu
// pencarian biasa memakai satu context; pencarian dengan detail=true memakai
// satu context ditambah satu per hasil yang diperkaya.
const IDLE_TIMEOUT_MS = toInt(process.env.BROWSER_IDLE_TIMEOUT_MS, 300_000);
const MAX_CONTEXTS = toInt(process.env.BROWSER_MAX_CONTEXTS, 200);

function toInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

let browserPromise = null;
// Berapa context yang sedang berjalan. Browser hanya boleh ditutup saat 0.
let activeContexts = 0;
let contextsServed = 0;
// Ditandai true ketika kuota context habis; penutupan menunggu context terakhir.
let retiring = false;
let idleTimer = null;

function clearIdleTimer() {
  if (idleTimer) {
    clearTimeout(idleTimer);
    idleTimer = null;
  }
}

// Melepas browser saat ini. Referensinya dibuang secara sinkron lebih dulu agar
// permintaan yang datang di sela-sela penutupan mendapat browser baru, bukan
// browser yang sedang ditutup.
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

  // Timer tidak boleh menahan proses tetap hidup saat hendak berhenti.
  idleTimer.unref?.();
}

function launchBrowser() {
  const promise = openBrowser().then((browser) => {
    browser.on('disconnected', () => {
      // Hanya bereaksi kalau ini memang browser yang sedang aktif. Tanpa
      // penjagaan ini, sinyal dari browser lama bisa membuang browser
      // pengganti yang baru saja dinyalakan.
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

  // Kuota sudah habis dan tidak ada yang memakai: tutup sekarang, lalu
  // nyalakan yang baru untuk permintaan ini.
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

// Dilaporkan lewat GET /health agar perilaku daur hidupnya dapat diamati.
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

export async function withPage(options, callback) {
  const { lang = 'id', country = 'ID', timeout = 45000, blockAssets = true } = options;
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

    if (blockAssets) {
      // Memutus request gambar membuat Google tidak menyisipkan elemen <img> sama sekali,
      // sehingga URL foto ikut hilang. Karena itu gambar dijawab dengan piksel 1x1:
      // DOM tetap utuh, byte foto asli tidak diunduh.
      await context.route('**/*', (route) => {
        const type = route.request().resourceType();
        if (type === 'image') {
          return route.fulfill({ status: 200, contentType: 'image/gif', body: PIXEL });
        }
        if (type === 'media' || type === 'font') return route.abort();
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

// Halaman consent sesekali tetap muncul walau cookie sudah dipasang.
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

// Dipanggil saat proses berhenti; menunggu penutupan benar-benar selesai.
// Untuk browser milik server lain, close() hanya memutus sambungan.
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
