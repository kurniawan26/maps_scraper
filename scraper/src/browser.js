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

let browserPromise = null;

export async function getBrowser() {
  if (!browserPromise) {
    browserPromise = openBrowser().then((browser) => {
      // Kalau browser mati (OOM, crash, atau server remote putus), buang cache-nya
      // supaya request berikutnya menyambung/launch ulang.
      browser.on('disconnected', () => {
        browserPromise = null;
      });
      return browser;
    });
  }

  try {
    return await browserPromise;
  } catch (error) {
    browserPromise = null;
    throw error;
  }
}

export async function withPage(options, callback) {
  const { lang = 'id', country = 'ID', timeout = 45000, blockAssets = true } = options;
  const browser = await getBrowser();

  const context = await browser.newContext({
    locale: `${lang}-${country}`,
    timezoneId: process.env.TZ || 'Asia/Jakarta',
    viewport: { width: 1440, height: 900 },
    userAgent:
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
    extraHTTPHeaders: { 'Accept-Language': `${lang}-${country},${lang};q=0.9` }
  });

  try {
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
    await context.close().catch(() => {});
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
    await button.click({ timeout: 5000 }).catch(() => {});
  });
}

export async function closeBrowser() {
  if (!browserPromise) return;
  const browser = await browserPromise.catch(() => null);
  browserPromise = null;
  if (!browser) return;

  // Browser milik server lain hanya diputus sambungannya, bukan dimatikan.
  if (WS_ENDPOINT || CDP_ENDPOINT) {
    await browser.close().catch(() => {});
    return;
  }

  await browser.close().catch(() => {});
}
