// Helper murni (tanpa browser) yang dipakai lintas modul.

const SHORT_LINK_HOSTS = ['maps.app.goo.gl', 'goo.gl', 'g.co'];
const MAPS_HOSTS = ['google.com', 'google.co.id', 'maps.google.com'];

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

  const isGoogleHost =
    MAPS_HOSTS.includes(host) || /(^|\.)google\.[a-z.]{2,}$/i.test(host);

  return isGoogleHost && /\/maps(\/|$|\?)/.test(url.pathname + url.search);
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
    if (parsed.hostname.replace(/^www\./, '').startsWith('google')) {
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

  const hits = queryTokens.filter(
    (token) =>
      target.has(token) || Array.from(target).some((word) => word.startsWith(token))
  ).length;

  return Math.round((hits / queryTokens.length) * 100) / 100;
}
