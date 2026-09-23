import { withPage } from './browser.js';
import { ScrapeError, matchScore } from './util.js';

// Dua platform, dua cara baca yang berlawanan — dan itu hasil pengukuran,
// bukan pilihan:
//
//   Tokopedia  HTTP polos berhasil dan mengembalikan og:title berisi nama toko;
//              toko yang tidak ada dijawab 410 Gone. Browser justru DITOLAK di
//              lapis HTTP/2 (ERR_HTTP2_PROTOCOL_ERROR), jadi memakai browser di
//              sini bukan cuma mahal, tapi tidak jalan.
//
//   Shopee     HTTP polos hanya mendapat shell kosong yang identik untuk toko
//              ada maupun tidak, dan API-nya menolak dengan 403. Tetapi DI DALAM
//              browser, API yang sama dipanggil frontend-nya sendiri dan balas
//              200 — jadi halamannya dibuka, lalu responsnya disadap.

const USER_AGENT =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

// Endpoint internal yang dipanggil halaman toko Shopee.
const SHOPEE_SHOP_API = /\/api\/v4\/shop\/get_shop_base/;

// Berapa lama menunggu frontend Shopee memanggil API-nya sendiri.
const SHOPEE_API_WAIT_MS = 12_000;

function notFound(query, platform, reason) {
  return {
    type: 'marketplace',
    platform,
    query,
    found: false,
    best_match: 0,
    count: 0,
    reason,
    results: []
  };
}

function unreadable(platform, reason, message) {
  throw new ScrapeError(message, { status: 503, code: `${platform}_${reason}` });
}

function found(query, platform, store, name) {
  // Tanpa `name`, pertanyaannya cuma "apakah toko di URL ini ada" — dan URL-nya
  // menunjuk satu toko secara pasti, jadi jawabannya 1. Dengan `name`,
  // pertanyaannya "apakah toko ini milik usaha bernama X", dan itu diukur
  // dengan matchScore yang sama dengan sumber lain.
  const match = name
    ? matchScore(name, { name: store.store_name, address: store.slug, category: platform })
    : 1;

  return {
    type: 'marketplace',
    platform,
    query,
    found: true,
    best_match: match,
    count: 1,
    reason: null,
    results: [{ ...store, platform, match }]
  };
}

// --- Tokopedia -------------------------------------------------------------

// og:title berbentuk "Toko <Nama> Online - Produk Lengkap & Harga Terbaik | Tokopedia".
function tokopediaName(ogTitle) {
  if (typeof ogTitle !== 'string') return null;

  const match = ogTitle.match(/^Toko\s+(.+?)\s+Online\b/i);
  if (match) return match[1].trim() || null;

  // Kalau formatnya berubah, judulnya dipakai apa adanya — lebih baik daripada
  // melaporkan toko tanpa nama.
  return ogTitle.replace(/\s*\|\s*Tokopedia\s*$/i, '').trim() || null;
}

function metaContent(html, property) {
  const pattern = new RegExp(
    `<meta[^>]*property=["']${property}["'][^>]*content=["']([^"']*)["']`,
    'i'
  );
  const match = html.match(pattern);
  if (!match) return null;

  return match[1]
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
    .trim();
}

// Tokopedia memasang Bot Manager Akamai di sebagian toko. Yang dikirim bukan
// status error, melainkan halaman 200 berukuran kecil berisi meta-refresh ke
// URL ber-token `bm-verify`. Perilakunya konsisten per toko, bukan acak:
// sebagian toko selalu ditantang, sebagian tidak pernah.
//
// Mengikuti URL itu sekali, dengan cookie yang baru saja diberikan, cukup untuk
// mendapatkan halaman aslinya.
const TOKOPEDIA_CHALLENGE_MAX_BYTES = 8_000;

function looksChallenged(html) {
  return html.length < TOKOPEDIA_CHALLENGE_MAX_BYTES && /bm-verify|http-equiv="refresh"/i.test(html);
}

function challengeTarget(html, base) {
  const match = html.match(/URL=['"]?([^'"\s>]+)/i);
  if (!match) return null;

  try {
    return new URL(match[1], base).toString();
  } catch {
    return null;
  }
}

async function fetchTokopedia(url, { timeout, lang, country, cookie = null, referer = null }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);

  try {
    return await fetch(url, {
      signal: controller.signal,
      headers: {
        'user-agent': USER_AGENT,
        'accept-language': `${lang}-${country},${lang};q=0.9`,
        accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        ...(cookie ? { cookie } : {}),
        ...(referer ? { referer } : {})
      }
    });
  } catch (error) {
    const message = describeFailure(error);
    const reason = /AbortError|aborted|ETIMEDOUT/i.test(message) ? 'timeout' : 'unreadable';
    unreadable('tokopedia', reason, 'Tokopedia tidak dapat dihubungi dalam batas waktu');
  } finally {
    clearTimeout(timer);
  }
}

function classifyTokopediaStatus(status) {
  // 410 Gone adalah jawaban Tokopedia untuk toko yang tidak ada — status HTTP
  // standar yang berarti persis itu, bukan tebakan dari isi halaman.
  if (status === 404 || status === 410) return 'missing';

  // 403/429 berarti kita yang ditolak, bukan tokonya yang tidak ada.
  if (status === 401 || status === 403 || status === 429 || status >= 500) return 'unreadable';

  return 'ok';
}

async function readTokopedia(store, { timeout, lang, country }) {
  const settings = { timeout, lang, country };

  let response = await fetchTokopedia(store.url, settings);
  let status = response.status;

  if (classifyTokopediaStatus(status) === 'missing') return { missing: true, status };
  if (classifyTokopediaStatus(status) === 'unreadable') {
    unreadable('tokopedia', `http_${status}`, `Tokopedia menjawab ${status}`);
  }

  let html = await response.text();

  if (looksChallenged(html)) {
    const target = challengeTarget(html, store.url);
    const jar = (response.headers.getSetCookie?.() ?? [])
      .map((entry) => entry.split(';')[0])
      .join('; ');

    if (!target) {
      unreadable('tokopedia', 'challenged', 'Tokopedia meminta verifikasi bot');
    }

    response = await fetchTokopedia(target, { ...settings, cookie: jar, referer: store.url });
    status = response.status;

    if (classifyTokopediaStatus(status) === 'missing') return { missing: true, status };
    if (classifyTokopediaStatus(status) === 'unreadable') {
      unreadable('tokopedia', `http_${status}`, `Tokopedia menjawab ${status}`);
    }

    html = await response.text();

    // Masih ditantang setelah dijawab sekali: itu "tidak tahu", bukan
    // "toko tidak ada". Antrean yang akan mengulangnya.
    if (looksChallenged(html)) {
      unreadable('tokopedia', 'challenged', 'Tokopedia meminta verifikasi bot');
    }
  }

  const ogTitle = metaContent(html, 'og:title');

  if (!ogTitle) {
    unreadable('tokopedia', 'unreadable', 'Halaman toko tidak dapat dibaca');
  }

  return {
    missing: false,
    status,
    store: {
      slug: store.slug,
      store_name: tokopediaName(ogTitle),
      store_url: metaContent(html, 'og:url') || store.url,
      shop_id: null,
      followers: null,
      items: null,
      rating: null
    }
  };
}

// --- Shopee ----------------------------------------------------------------

async function readShopeeOnce(store, { timeout, lang, country }) {
  return withPage({ lang, country, timeout }, async (page) => {
    let payload = null;

    page.on('response', async (response) => {
      if (payload || !SHOPEE_SHOP_API.test(response.url())) return;
      try {
        payload = await response.json();
      } catch {
        // Respons yang bukan JSON tidak memberi tahu apa-apa; tunggu yang berikutnya.
      }
    });

    await page.goto(store.url, { waitUntil: 'domcontentloaded', timeout });

    // Halaman Shopee tidak pernah merender nama tokonya untuk kita; yang
    // ditunggu adalah panggilan API-nya sendiri, bukan elemen di DOM.
    const deadline = Date.now() + Math.min(timeout, SHOPEE_API_WAIT_MS);
    while (!payload && Date.now() < deadline) {
      await page.waitForTimeout(250);
    }

    return payload;
  });
}

async function readShopee(store, options) {
  let payload = await readShopeeOnce(store, options);

  // API tidak pernah dipanggil sama sekali: kita diblokir atau halamannya tidak
  // selesai. Itu "tidak tahu", bukan "toko tidak ada".
  if (!payload) {
    unreadable('shopee', 'blocked', 'Shopee tidak mengembalikan data toko');
  }

  if (payload.error === 0 && payload.data?.name) return shopeeStore(store, payload);

  // Shopee menjawab kegagalan dengan kode generik `1000000 service_err`, yang
  // sama bunyinya untuk "toko tidak ada" maupun "layanan sedang bermasalah".
  // Karena itu dikonfirmasi sekali lagi sebelum divonis: gangguan sesaat jarang
  // terulang persis, sedangkan toko yang memang tidak ada selalu menjawab sama.
  const konfirmasi = await readShopeeOnce(store, options);

  if (!konfirmasi) {
    unreadable('shopee', 'blocked', 'Shopee tidak mengembalikan data toko');
  }

  if (konfirmasi.error === 0 && konfirmasi.data?.name) return shopeeStore(store, konfirmasi);

  return { missing: true, status: 200 };
}

function shopeeStore(store, payload) {
  const data = payload.data;

  return {
    missing: false,
    status: 200,
    store: {
      slug: store.slug,
      store_name: data.name,
      store_url: store.url,
      shop_id: data.shopid ?? null,
      followers: data.follower_count ?? null,
      items: data.item_count ?? null,
      rating: data.shop_rating?.rating_star ?? data.rating_star ?? null
    }
  };
}

// --- Bersama ---------------------------------------------------------------

function describeFailure(error) {
  const parts = [];
  let current = error;

  for (let depth = 0; current && depth < 5; depth += 1) {
    if (current.code) parts.push(String(current.code));
    if (current.message) parts.push(String(current.message));
    current = current.cause;
  }

  return parts.join(' ');
}

export async function scrapeMarketplace(store, options = {}) {
  const { lang = 'id', country = 'ID', timeout = 45000, name = null, query = store.url } = options;
  const settings = { lang, country, timeout };

  const hasil =
    store.platform === 'tokopedia'
      ? await readTokopedia(store, settings)
      : await readShopee(store, settings);

  if (hasil.missing) {
    return notFound(query, store.platform, `store_not_found_${hasil.status}`);
  }

  return found(query, store.platform, hasil.store, name);
}
