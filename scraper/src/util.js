
export class ScrapeError extends Error {
  constructor(message, { status = 502, code = 'scrape_failed' } = {}) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const SHORT_LINK_HOSTS = ['maps.app.goo.gl', 'goo.gl', 'g.co'];
const GOOGLE_HOST = /^(?:[a-z0-9-]+\.)*google\.(?:com|[a-z]{2})(?:\.[a-z]{2})?$/i;

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

export function coordsFromUrl(url) {
  if (typeof url !== 'string') return { latitude: null, longitude: null };

  const exact = url.match(/!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/);
  if (exact) return { latitude: Number(exact[1]), longitude: Number(exact[2]) };

  const center = url.match(/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/);
  if (center) return { latitude: Number(center[1]), longitude: Number(center[2]) };

  return { latitude: null, longitude: null };
}

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

export function toFloat(value) {
  if (typeof value === 'number') return value;
  if (typeof value !== 'string') return null;
  const match = value.replace(/\s/g, '').match(/-?\d+(?:[.,]\d+)?/);
  if (!match) return null;
  const parsed = Number(match[0].replace(',', '.'));
  return Number.isFinite(parsed) ? parsed : null;
}

export function toCount(value) {
  if (typeof value === 'number') return value;
  if (typeof value !== 'string') return null;
  const match = value.match(/\d[\d.,\s]*/);
  if (!match) return null;
  const parsed = Number(match[0].replace(/[.,\s]/g, ''));
  return Number.isFinite(parsed) ? parsed : null;
}

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

export function isCoordinates(value) {
  return typeof value === 'string' && /^\s*-?\d{1,3}(\.\d+)?\s*,\s*-?\d{1,3}(\.\d+)?\s*$/.test(value);
}

export function matchScore(query, place) {
  if (isCoordinates(query)) return null;

  const queryTokens = tokenize(query);
  if (queryTokens.length === 0) return null;

  const target = new Set(tokenize([place.name, place.address, place.category].join(' ')));
  if (target.size === 0) return 0;

  const targetWords = Array.from(target);

  const hits = queryTokens.filter(
    (token) => target.has(token) || targetWords.some((word) => word.startsWith(token))
  ).length;

  return Math.round((hits / queryTokens.length) * 100) / 100;
}

const INSTAGRAM_HOSTS = ['instagram.com', 'instagr.am', 'ig.me'];
const INSTAGRAM_USERNAME = /^[a-z0-9._]{1,30}$/i;

const INSTAGRAM_RESERVED = new Set([
  'p', 'reel', 'reels', 'stories', 'explore', 'accounts', 'direct', 'tv', 's',
  'about', 'developer', 'legal', 'privacy', 'terms', 'api', 'challenge', 'oauth'
]);

export function instagramUsername(value) {
  if (typeof value !== 'string') return null;

  const trimmed = value.trim();
  if (!trimmed) return null;

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

const TIKTOK_HOSTS = ['tiktok.com', 'm.tiktok.com'];

const TIKTOK_USERNAME = /^[a-z0-9._]{1,30}$/i;

export function tiktokUsername(value) {
  if (typeof value !== 'string') return null;

  const trimmed = value.trim();
  if (!trimmed) return null;

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
    if (!TIKTOK_HOSTS.includes(host)) return null;

    const [first] = url.pathname.split('/').filter(Boolean);
    if (!first || !first.startsWith('@')) return null;

    const username = first.slice(1);
    return TIKTOK_USERNAME.test(username) ? username.toLowerCase() : null;
  }

  const bare = trimmed.replace(/^@/, '');
  return TIKTOK_USERNAME.test(bare) ? bare.toLowerCase() : null;
}

const COUNT_SUFFIX = { k: 1e3, rb: 1e3, m: 1e6, jt: 1e6, b: 1e9, t: 1e12 };

export function toSocialCount(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value !== 'string') return null;

  const match = value.trim().match(/(\d[\d.,\s]*)\s*(k|rb|m|jt|b|t)?\b/i);
  if (!match) return null;

  const suffix = match[2] ? COUNT_SUFFIX[match[2].toLowerCase()] : null;

  if (!suffix) return toCount(match[1]);

  const base = Number(match[1].replace(/\s/g, '').replace(',', '.'));
  return Number.isFinite(base) ? Math.round(base * suffix) : null;
}

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

  if (!['http:', 'https:'].includes(url.protocol)) return null;

  const host = url.hostname;

  if (isIpLiteral(host)) return url.toString();

  return HOSTNAME.test(host) ? url.toString() : null;
}

export function isIpLiteral(host) {
  if (typeof host !== 'string') return false;
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.includes(':');
}

function ipv4Blocked([a, b, c, d]) {
  if (a === 0) return true;
  if (a === 10) return true;
  if (a === 127) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 100 && b >= 64 && b <= 127) return true;
  if (a === 192 && b === 0 && c === 0) return true;
  if (a === 192 && b === 0 && c === 2) return true;
  if (a === 198 && (b === 18 || b === 19)) return true;
  if (a === 198 && b === 51 && c === 100) return true;
  if (a === 203 && b === 0 && c === 113) return true;
  if (a >= 224) return true;
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

  const mapped = lower.match(/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (mapped) return isBlockedAddress(mapped[1]);

  if (/^(fc|fd)[0-9a-f]{2}:/.test(lower)) return true;
  if (/^fe[89ab][0-9a-f]:/.test(lower)) return true;
  if (/^ff[0-9a-f]{2}:/.test(lower)) return true;

  return false;
}

const MARKETPLACE_PLATFORMS = [
  {
    name: 'tokopedia',
    host: /^(?:[a-z0-9-]+\.)?tokopedia\.com$/i,
    reserved: new Set([
      'search', 'cart', 'help', 'about', 'promo', 'discovery', 'p', 'find',
      'login', 'register', 'wishlist', 'order-list', 'contact-us', 'rewards'
    ])
  },
  {
    name: 'shopee',
    host: /^(?:[a-z0-9-]+\.)?shopee\.(?:co\.id|com|sg|ph|vn|co\.th|com\.my|com\.br|tw)$/i,
    reserved: new Set([
      'search', 'cart', 'daily-discover', 'buyer', 'seller', 'help', 'about',
      'mall', 'product', 'shop', 'user', 'login', 'register', 'm', 'web'
    ])
  }
];

const STORE_SLUG = /^[a-z0-9._-]{1,64}$/i;

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
