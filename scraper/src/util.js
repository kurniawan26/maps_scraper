// Helper murni (tanpa browser) yang dipakai lintas modul.

// Error yang sudah membawa status HTTP dan kode mesinnya sendiri. Ditaruh di sini,
// bukan di salah satu modul scraper, karena dipakai maps.js maupun instagram.js
// dan server.js yang menerjemahkannya jadi response.
export class ScrapeError extends Error {
  constructor(message, { status = 502, code = 'scrape_failed' } = {}) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const SHORT_LINK_HOSTS = ['maps.app.goo.gl', 'goo.gl', 'g.co'];
const GOOGLE_HOST = /^(?:[a-z0-9-]+\.)*google\.(?:com|[a-z]{2})(?:\.[a-z]{2})?$/i;

// Hostname sudah tanpa "www." di depan.
export function isGoogleHost(host) {
  return typeof host === 'string' && GOOGLE_HOST.test(host);
}

export function isMapsUrl(value) {
  if (typeof value !== 'string') return false;
  let url;
  try {
    url = new URL(value.trim());
  } catch {
    return false;
  }
  if (!['http:', 'https:'].includes(url.protocol)) return false;

  const host = url.hostname.replace(/^www\./, '');
  if (SHORT_LINK_HOSTS.includes(host)) return true;

  return isGoogleHost(host) && /\/maps(\/|$|\?)/.test(url.pathname + url.search);
}

// Google menaruh koordinat di beberapa tempat berbeda pada URL.
// !3d/!4d adalah titik tempat yang sebenarnya; @lat,lng hanya titik tengah peta.
export function coordsFromUrl(url) {
  if (typeof url !== 'string') return { latitude: null, longitude: null };

  const exact = url.match(/!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/);
  if (exact) return { latitude: Number(exact[1]), longitude: Number(exact[2]) };

  const center = url.match(/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/);
  if (center) return { latitude: Number(center[1]), longitude: Number(center[2]) };

  return { latitude: null, longitude: null };
}

// ftid berbentuk "0x2e69f1...:0x47d9b1..." — bagian kedua adalah CID tempat.
export function idsFromUrl(url) {
  if (typeof url !== 'string') return { ftid: null, cid: null, place_id: null };

  const ftidMatch =
    url.match(/!1s(0x[0-9a-f]+:0x[0-9a-f]+)/i) || url.match(/[?&]ftid=(0x[0-9a-f]+:0x[0-9a-f]+)/i);
  const placeIdMatch = url.match(/[?&]place_id=([\w-]+)/) || url.match(/!19s(ChI[\w-]+)/);

  let cid = null;
  if (ftidMatch) {
    try {
      cid = BigInt(ftidMatch[1].split(':')[1]).toString();
    } catch {
      cid = null;
    }
  }

  return {
    ftid: ftidMatch ? ftidMatch[1] : null,
    cid,
    place_id: placeIdMatch ? placeIdMatch[1] : null
  };
}

// "4,7" (id) dan "4.7" (en) sama-sama harus jadi 4.7
export function toFloat(value) {
  if (typeof value === 'number') return value;
  if (typeof value !== 'string') return null;
  const match = value.replace(/\s/g, '').match(/-?\d+(?:[.,]\d+)?/);
  if (!match) return null;
  const parsed = Number(match[0].replace(',', '.'));
  return Number.isFinite(parsed) ? parsed : null;
}

// "(1.234)" / "1,234 ulasan" / "2 rb ulasan" -> 1234
export function toCount(value) {
  if (typeof value === 'number') return value;
  if (typeof value !== 'string') return null;
  const match = value.match(/\d[\d.,\s]*/);
  if (!match) return null;
  const parsed = Number(match[0].replace(/[.,\s]/g, ''));
  return Number.isFinite(parsed) ? parsed : null;
}

// URL Maps yang disalin pengguna sering tidak lengkap (mis. hanya nama + @koordinat,
// tanpa segmen `data=`). Google membuka peta kosong untuk URL seperti itu, jadi nama
// tempat di path dipakai sebagai query pencarian cadangan.
export function queryFromMapsUrl(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }

  const param = parsed.searchParams.get('q') || parsed.searchParams.get('query');
  if (param && !param.startsWith('place_id:') && !/^-?\d+(\.\d+)?,/.test(param)) {
    return param.trim() || null;
  }

  const match = parsed.pathname.match(/\/maps\/(?:place|search)\/([^/@]+)/);
  if (!match) return null;

  let decoded;
  try {
    decoded = decodeURIComponent(match[1]);
  } catch {
    decoded = match[1];
  }

  decoded = decoded.replace(/\+/g, ' ').trim();
  return decoded && decoded !== 'data=' ? decoded : null;
}

export function searchUrl(query, { lang = 'id', country = 'ID' } = {}) {
  const params = new URLSearchParams({ hl: lang, gl: country });
  return `https://www.google.com/maps/search/${encodeURIComponent(query)}?${params}`;
}

// Memaksa bahasa hasil agar parsing label konsisten.
export function withLang(url, { lang = 'id', country = 'ID' } = {}) {
  try {
    const parsed = new URL(url);
    if (isGoogleHost(parsed.hostname.replace(/^www\./, ''))) {
      parsed.searchParams.set('hl', lang);
      parsed.searchParams.set('gl', country);
    }
    return parsed.toString();
  } catch {
    return url;
  }
}

export function clampInt(value, { min, max, fallback }) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

export async function mapWithConcurrency(items, limit, worker) {
  const results = new Array(items.length);
  let cursor = 0;

  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor++;
      results[index] = await worker(items[index], index);
    }
  });

  await Promise.all(runners);
  return results;
}

// Google selalu berusaha menjawab: untuk alamat fiktif pun ia mengembalikan tempat
// lain yang "sekilas mirip". Karena itu keberadaan hasil saja tidak cukup untuk
// menyatakan sebuah tempat valid — perlu ukuran seberapa cocok hasil dengan query.
const STOPWORDS = new Set([
  'di', 'ke', 'dan', 'yang', 'the', 'of', 'in', 'at',
  'jl', 'jln', 'jalan', 'no', 'nomor', 'kota', 'kab', 'kabupaten',
  'kec', 'kecamatan', 'kel', 'kelurahan', 'rt', 'rw', 'provinsi'
]);

function tokenize(value) {
  if (typeof value !== 'string') return [];
  return value
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .split(' ')
    .map((token) => token.trim())
    .filter((token) => token.length > 1 && !STOPWORDS.has(token));
}

// Proporsi kata bermakna dari query yang benar-benar muncul pada nama/alamat hasil.
// 1 berarti seluruh kata query terwakili; 0 berarti hasil tidak berhubungan.
export function isCoordinates(value) {
  return typeof value === 'string' && /^\s*-?\d{1,3}(\.\d+)?\s*,\s*-?\d{1,3}(\.\d+)?\s*$/.test(value);
}

export function matchScore(query, place) {
  // Koordinat dan URL menunjuk lokasi secara pasti; kemiripan teks tidak berlaku.
  if (isCoordinates(query)) return null;

  const queryTokens = tokenize(query);
  if (queryTokens.length === 0) return null;

  const target = new Set(tokenize([place.name, place.address, place.category].join(' ')));
  if (target.size === 0) return 0;

  // Diambil sekali di luar filter: di dalamnya, Array.from membangun ulang
  // seluruh daftar untuk tiap kata query.
  const targetWords = Array.from(target);

  const hits = queryTokens.filter(
    (token) => target.has(token) || targetWords.some((word) => word.startsWith(token))
  ).length;

  return Math.round((hits / queryTokens.length) * 100) / 100;
}

// --- Instagram -------------------------------------------------------------

const INSTAGRAM_HOSTS = ['instagram.com', 'instagr.am', 'ig.me'];
const INSTAGRAM_USERNAME = /^[a-z0-9._]{1,30}$/i;

// Segmen pertama URL Instagram yang bukan username. Tanpa daftar ini,
// "/p/ABC123/" akan dibaca sebagai profil bernama "p".
const INSTAGRAM_RESERVED = new Set([
  'p', 'reel', 'reels', 'stories', 'explore', 'accounts', 'direct', 'tv', 's',
  'about', 'developer', 'legal', 'privacy', 'terms', 'api', 'challenge', 'oauth'
]);

// Menerima "kournicloud", "@kournicloud", atau URL profil dalam berbagai bentuk,
// dan mengembalikan username huruf kecil — atau null kalau bukan salah satunya.
export function instagramUsername(value) {
  if (typeof value !== 'string') return null;

  const trimmed = value.trim();
  if (!trimmed) return null;

  // Username Instagram boleh memuat titik dan garis bawah, tetapi tidak pernah
  // garis miring. Kehadiran "/" karena itu cukup untuk membedakan tautan dari
  // username — termasuk tautan tanpa skema seperti "instagram.com/kournicloud",
  // yang justru bentuk paling sering disalin orang.
  if (trimmed.includes('/')) {
    const absolute = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;

    let url;
    try {
      url = new URL(absolute);
    } catch {
      return null;
    }

    if (!['http:', 'https:'].includes(url.protocol)) return null;

    const host = url.hostname.replace(/^www\./, '').toLowerCase();
    if (!INSTAGRAM_HOSTS.includes(host)) return null;

    const [first] = url.pathname.split('/').filter(Boolean);
    if (!first || INSTAGRAM_RESERVED.has(first.toLowerCase())) return null;

    return INSTAGRAM_USERNAME.test(first) ? first.toLowerCase() : null;
  }

  const bare = trimmed.replace(/^@/, '');
  return INSTAGRAM_USERNAME.test(bare) ? bare.toLowerCase() : null;
}

// Angka sosial datang dalam dua bentuk: lengkap dengan pemisah ribuan
// ("268.554.117", dari atribut title) atau sudah dibulatkan dengan akhiran
// ("269M", "32K", dari og:description). toCount/1 hanya menangani bentuk pertama
// dan akan membaca "269M" sebagai 269.
const COUNT_SUFFIX = { k: 1e3, rb: 1e3, m: 1e6, jt: 1e6, b: 1e9, t: 1e12 };

export function toSocialCount(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value !== 'string') return null;

  const match = value.trim().match(/(\d[\d.,\s]*)\s*(k|rb|m|jt|b|t)?\b/i);
  if (!match) return null;

  const suffix = match[2] ? COUNT_SUFFIX[match[2].toLowerCase()] : null;

  if (!suffix) return toCount(match[1]);

  // Dengan akhiran, pemisahnya adalah desimal ("1.5M"), bukan ribuan.
  const base = Number(match[1].replace(/\s/g, '').replace(',', '.'));
  return Number.isFinite(base) ? Math.round(base * suffix) : null;
}

// --- Website ---------------------------------------------------------------

// Menerima "warungsate.com", "www.warungsate.com/kontak", atau URL lengkap, dan
// mengembalikan URL absolut. Domain telanjang dinaikkan ke https lebih dulu;
// sidecar yang menurunkannya ke http kalau https-nya memang tidak ada.
// Host satu suku kata ("localhost", "intranet") sengaja ikut diterima di sini.
// Menolaknya sebagai "bukan domain" menyesatkan — yang benar adalah
// meneruskannya ke pemeriksa alamat, yang akan menolaknya sebagai alamat
// internal. Nama yang memang tidak ada berakhir sebagai dns_not_found.
const HOSTNAME =
  /^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/i;

export function websiteUrl(value) {
  if (typeof value !== 'string') return null;

  const trimmed = value.trim();
  if (!trimmed || /\s/.test(trimmed)) return null;

  const candidate = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;

  let url;
  try {
    url = new URL(candidate);
  } catch {
    return null;
  }

  // Hanya http(s). Tanpa penjagaan ini, "file:///etc/passwd" dan
  // "data:text/html,..." ikut diterima sebagai "website".
  if (!['http:', 'https:'].includes(url.protocol)) return null;

  const host = url.hostname;

  // Alamat IP telanjang diterima di sini dan disaring assertPublicHost/1 —
  // pemeriksaannya sama untuk IP literal maupun hasil resolusi DNS.
  if (isIpLiteral(host)) return url.toString();

  return HOSTNAME.test(host) ? url.toString() : null;
}

export function isIpLiteral(host) {
  if (typeof host !== 'string') return false;
  // URL membungkus IPv6 dengan kurung siku; hostname sudah melepasnya.
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.includes(':');
}

// --- Penjagaan SSRF --------------------------------------------------------
//
// Berbeda dari Maps dan Instagram yang host-nya terkunci, sumber "website"
// membuka URL yang ditentukan pemanggil. Tanpa penyaring di bawah ini, siapa
// pun bisa memakai service ini sebagai perantara untuk menjangkau apa yang
// hanya terlihat dari dalam jaringan: metadata cloud di 169.254.169.254,
// Phoenix di app:4000, atau sidecar ini sendiri.
//
// Yang diperiksa adalah ALAMAT HASIL RESOLUSI, bukan namanya. Nama domain
// publik bisa saja mengarah ke 127.0.0.1, dan pemeriksaan berbasis nama tidak
// akan melihatnya.

function ipv4Blocked([a, b, c, d]) {
  if (a === 0) return true; // 0.0.0.0/8
  if (a === 10) return true; // privat
  if (a === 127) return true; // loopback
  if (a === 169 && b === 254) return true; // link-local, termasuk metadata cloud
  if (a === 172 && b >= 16 && b <= 31) return true; // privat
  if (a === 192 && b === 168) return true; // privat
  if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT
  if (a === 192 && b === 0 && c === 0) return true; // IETF protocol assignments
  if (a === 192 && b === 0 && c === 2) return true; // TEST-NET-1
  if (a === 198 && (b === 18 || b === 19)) return true; // benchmarking
  if (a === 198 && b === 51 && c === 100) return true; // TEST-NET-2
  if (a === 203 && b === 0 && c === 113) return true; // TEST-NET-3
  if (a >= 224) return true; // multicast dan sisanya yang dicadangkan
  void d;
  return false;
}

export function isBlockedAddress(address) {
  if (typeof address !== 'string') return true;

  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(address)) {
    const parts = address.split('.').map(Number);
    if (parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return true;
    return ipv4Blocked(parts);
  }

  const lower = address.toLowerCase().replace(/%.*$/, '');

  if (lower === '::' || lower === '::1') return true;

  // IPv4 yang dipetakan ke IPv6 (::ffff:127.0.0.1) menembus pemeriksaan IPv6
  // kalau tidak dikembalikan dulu ke bentuk IPv4-nya.
  const mapped = lower.match(/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (mapped) return isBlockedAddress(mapped[1]);

  if (/^(fc|fd)[0-9a-f]{2}:/.test(lower)) return true; // fc00::/7 unique local
  if (/^fe[89ab][0-9a-f]:/.test(lower)) return true; // fe80::/10 link-local
  if (/^ff[0-9a-f]{2}:/.test(lower)) return true; // multicast

  return false;
}

// --- Marketplace -----------------------------------------------------------
//
// Berbeda dari sumber "website" yang membuka URL mana pun, di sini host-nya
// terkunci ke dua platform. Karena itu tidak ada penjagaan SSRF: tidak ada
// masukan yang bisa mengarahkannya ke alamat internal.

const MARKETPLACE_PLATFORMS = [
  {
    name: 'tokopedia',
    host: /^(?:[a-z0-9-]+\.)?tokopedia\.com$/i,
    // Jalur yang bukan toko. Tanpa daftar ini "tokopedia.com/search" dibaca
    // sebagai toko bernama "search".
    reserved: new Set([
      'search', 'cart', 'help', 'about', 'promo', 'discovery', 'p', 'find',
      'login', 'register', 'wishlist', 'order-list', 'contact-us', 'rewards'
    ])
  },
  {
    name: 'shopee',
    // Shopee memakai domain berbeda per negara. Hanya shopee.co.id yang
    // benar-benar diuji; yang lain mengikuti pola yang sama.
    host: /^(?:[a-z0-9-]+\.)?shopee\.(?:co\.id|com|sg|ph|vn|co\.th|com\.my|com\.br|tw)$/i,
    reserved: new Set([
      'search', 'cart', 'daily-discover', 'buyer', 'seller', 'help', 'about',
      'mall', 'product', 'shop', 'user', 'login', 'register', 'm', 'web'
    ])
  }
];

// Nama toko: huruf, angka, titik, garis bawah, strip.
const STORE_SLUG = /^[a-z0-9._-]{1,64}$/i;

/**
 * Menguraikan "tokopedia.com/samsung", "https://shopee.co.id/samsung.id", dan
 * bentuk sejenisnya menjadi { platform, slug, url }.
 *
 * Mengembalikan null untuk host di luar kedua platform, untuk jalur yang bukan
 * toko (keranjang, pencarian, halaman produk), dan untuk masukan yang tidak
 * menyebut host sama sekali — nama toko telanjang ambigu, karena "samsung" ada
 * di kedua platform sebagai toko yang berbeda.
 */
export function marketplaceStore(value) {
  if (typeof value !== 'string') return null;

  const trimmed = value.trim();
  if (!trimmed || /\s/.test(trimmed)) return null;

  const candidate = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;

  let url;
  try {
    url = new URL(candidate);
  } catch {
    return null;
  }

  if (!['http:', 'https:'].includes(url.protocol)) return null;

  const platform = MARKETPLACE_PLATFORMS.find((entry) => entry.host.test(url.hostname));
  if (!platform) return null;

  const segments = url.pathname.split('/').filter(Boolean);
  if (segments.length !== 1) return null;

  const slug = segments[0];
  if (platform.reserved.has(slug.toLowerCase())) return null;
  if (!STORE_SLUG.test(slug)) return null;

  return { platform: platform.name, slug, url: storeUrl(platform.name, slug) };
}

function storeUrl(platform, slug) {
  const host = platform === 'tokopedia' ? 'www.tokopedia.com' : 'shopee.co.id';
  return `https://${host}/${encodeURIComponent(slug)}`;
}
