import { extractWhenStable, withPage } from './browser.js';
import { extractPage } from './extract.js';
import { hostAllowed } from './guard.js';
import { ScrapeError, matchScore } from './util.js';

const MAX_REDIRECTS = 10;

// Batas menunggu halaman selesai memuat sebelum dibaca.
const SETTLE_TIMEOUT_MS = 10_000;

const USER_AGENT =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

// Layanan penjual/parkir domain. Halaman parkir isinya nyaris kosong tetapi
// selalu menautkan atau mengalihkan ke salah satu dari ini.
const PARKING_HOSTS = [
  'sedoparking.com', 'sedo.com', 'afternic.com', 'dan.com', 'bodis.com',
  'parkingcrew.net', 'hugedomains.com', 'above.com', 'sav.com', 'undeveloped.com',
  'domainmarket.com', 'buydomains.com'
];

// Ditulis dengan sengaja sempit. Vonis "parkir" berarti found: false, jadi salah
// tuduh di sini menghapus website usaha yang sebenarnya hidup. Frasa yang cuma
// "coming soon" atau "under construction" TIDAK dihitung parkir — halaman
// seperti itu memang hidup, hanya belum berisi.
const PARKING_PHRASES =
  /\b(this domain (?:name )?is for sale|buy this domain|the domain .{0,40} is for sale|domain (?:is )?parked|parked (?:free )?(?:courtesy|at)|inquire about this domain|domain ini dijual)\b/i;

// Di bawah ini halaman dianggap tidak berisi apa-apa — dipakai bersama sinyal
// parkir, tidak pernah sendirian.
const THIN_TEXT_LENGTH = 300;

// Untuk PERBANDINGAN dan pelaporan: "www." dibuang supaya www.contoh.com dan
// contoh.com dihitung domain yang sama.
function hostOf(value) {
  try {
    return new URL(value).hostname.replace(/^www\./, '').toLowerCase();
  } catch {
    return null;
  }
}

// Untuk PEMERIKSAAN ALAMAT: hostname apa adanya. Membuang "www." di sini adalah
// kekeliruan yang halus — www.contoh.com dan contoh.com bisa menunjuk alamat
// yang sama sekali berbeda, dan sebagian host hanya punya record pada salah
// satunya. Memeriksa nama yang salah berarti memeriksa mesin yang salah.
function exactHost(value) {
  try {
    return new URL(value).hostname.toLowerCase();
  } catch {
    return null;
  }
}

// Pesan sebab pada fetch Node bersembunyi di `cause`, bukan di message: yang
// terlihat hanya "fetch failed", sementara ENOTFOUND-nya satu tingkat di bawah.
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

function blocked() {
  return new ScrapeError('URL mengarah ke alamat internal dan tidak boleh dibuka', {
    // 403, bukan 5xx: ini masalah pada masukannya dan tidak akan berubah
    // kalau diulang.
    status: 403,
    code: 'blocked_address'
  });
}

// Kegagalan yang berarti "tidak tahu". Dikembalikan sebagai 5xx supaya
// MapsScraper.Validation.Queue mengulangnya, bukan memvonis barisnya mati.
function unreadable(reason, message) {
  throw new ScrapeError(message, { status: 503, code: `website_${reason}` });
}

function notFound(query, url, reason) {
  return { type: 'website', query, found: false, best_match: 0, count: 0, reason, results: [] };
}

// Dua dialek bercampur di sini: pesan Node (ENOTFOUND, ECONNREFUSED) dari
// praresolusi, dan pesan Chromium (ERR_*) dari navigasi.
function classifyFailure(message) {
  if (/ENOTFOUND|EAI_AGAIN|getaddrinfo|ERR_NAME_NOT_RESOLVED|ERR_NAME_RESOLUTION_FAILED/i.test(message)) {
    return 'dns_not_found';
  }
  if (/ECONNREFUSED|ERR_CONNECTION_REFUSED/i.test(message)) return 'connection_refused';
  if (/EHOSTUNREACH|ENETUNREACH|ERR_ADDRESS_UNREACHABLE|ERR_ADDRESS_INVALID/i.test(message)) {
    return 'unreachable';
  }
  if (/ERR_TOO_MANY_REDIRECTS|TOO_MANY_REDIRECTS/i.test(message)) return 'too_many_redirects';
  if (/certificate|CERT_|SELF_SIGNED|ERR_CERT|ERR_SSL|ERR_TLS|EPROTO/i.test(message)) {
    return 'tls_error';
  }
  if (/AbortError|This operation was aborted|timeout|ETIMEDOUT|ERR_TIMED_OUT|ERR_CONNECTION_TIMED_OUT|exceeded/i.test(message)) {
    return 'timeout';
  }
  return 'unreadable';
}

// Status HTTP dipisah tiga arah, bukan dua. 401/403/429 berarti halamannya ada
// tetapi kita tidak diizinkan melihatnya — memvonisnya mati akan menghapus
// website yang sekadar memblokir bot.
function classifyStatus(status) {
  if (status >= 200 && status < 300) return { kind: 'ok' };
  if (status === 404 || status === 410) return { kind: 'dead', reason: `http_${status}` };
  if (status === 401 || status === 403 || status === 429) {
    return { kind: 'unreadable', reason: `http_${status}` };
  }
  if (status >= 500) return { kind: 'unreadable', reason: `http_${status}` };
  return { kind: 'dead', reason: `http_${status}` };
}

/**
 * Menyelesaikan rantai pengalihan DI LUAR browser, memeriksa tiap lompatan.
 *
 * Ini tempat penjagaan SSRF yang sebenarnya. `route.continue()` di Playwright
 * hanya memanggil handler untuk request pertama — pengalihan sesudahnya diikuti
 * browser tanpa melewatinya lagi, sehingga URL publik yang mengalihkan ke
 * 127.0.0.1 akan lolos. Dengan menyelesaikan rantainya lebih dulu, browser
 * hanya pernah diarahkan ke URL yang sudah diperiksa.
 *
 * Bonus: halaman mati (404, DNS gagal) terjawab tanpa membuka browser sama
 * sekali — satu permintaan HTTP, bukan satu context Chromium.
 */
async function resolveChain(url, { timeout, lang, country }) {
  let current = url;
  let redirected = false;

  for (let hop = 0; ; hop += 1) {
    const host = exactHost(current);
    if (!host || !(await hostAllowed(host))) throw blocked();

    if (hop > MAX_REDIRECTS) throw new Error('ERR_TOO_MANY_REDIRECTS');

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);

    let response;
    try {
      response = await fetch(current, {
        redirect: 'manual',
        signal: controller.signal,
        headers: {
          'user-agent': USER_AGENT,
          'accept-language': `${lang}-${country},${lang};q=0.9`,
          accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        }
      });
    } finally {
      clearTimeout(timer);
    }

    // Isinya tidak dipakai — browser yang akan mengambilnya lagi. Aliran
    // datanya ditutup supaya koneksinya tidak menggantung.
    await response.body?.cancel().catch(() => {});

    const status = response.status;
    const location = status >= 300 && status < 400 ? response.headers.get('location') : null;

    if (!location) return { finalUrl: current, status, redirected };

    let next;
    try {
      next = new URL(location, current);
    } catch {
      throw new Error('ERR_INVALID_REDIRECT');
    }

    // Pengalihan ke skema lain (file:, data:) tidak pernah sah di sini.
    if (!['http:', 'https:'].includes(next.protocol)) throw blocked();

    current = next.toString();
    redirected = true;
  }
}

// Lapis kedua, untuk pengalihan yang hanya terjadi pada browser — misalnya
// karena server membalas berbeda untuk User-Agent Chromium. Tidak dapat
// mencegah lompatannya terjadi, tetapi menolak hasilnya.
async function assertChainAllowed(response, page) {
  const visited = [page.url()];

  let request = response?.request();
  while (request) {
    visited.push(request.url());
    request = request.redirectedFrom();
  }

  for (const url of visited) {
    const host = exactHost(url);
    if (!host || !(await hostAllowed(host))) throw blocked();
  }
}

function looksParked(page, finalUrl) {
  const finalHost = hostOf(finalUrl);

  const parkedHost = PARKING_HOSTS.some(
    (host) => finalHost === host || finalHost?.endsWith(`.${host}`)
  );
  if (parkedHost) return true;

  const linksToParking = (page.link_hosts || []).some((host) =>
    PARKING_HOSTS.some((parking) => host === parking || host.endsWith(`.${parking}`))
  );

  const haystack = [page.title, page.heading, page.description, page.text_sample]
    .filter(Boolean)
    .join(' ');

  // Frasa penjualan sudah cukup sendirian; tautan ke layanan parkir baru
  // dihitung kalau halamannya memang kosong, karena situs biasa pun sesekali
  // menautkan ke registrar.
  return PARKING_PHRASES.test(haystack) || (linksToParking && page.text_length < THIN_TEXT_LENGTH);
}

async function render(finalUrl, { lang, country, timeout }) {
  return withPage(
    {
      lang,
      country,
      timeout,
      handleRequest: async (route, request) => {
        const host = exactHost(request.url());
        if (!host || !(await hostAllowed(host))) return route.abort('blockedbyclient');
        return route.continue();
      }
    },
    async (page) => {
      const response = await page.goto(finalUrl, { waitUntil: 'domcontentloaded', timeout });

      await assertChainAllowed(response, page);

      // Sebagian situs berpindah ke alamat kanoniknya (mis. ke www) SETELAH
      // domcontentloaded. Membaca di titik itu menangkap halaman peralihan
      // yang judulnya masih kosong. Menunggu 'load' membuat pembacaan terjadi
      // pada halaman tujuan; batasnya dipendekkan supaya situs dengan aset
      // lambat tidak menahan seluruh permintaan.
      await page
        .waitForLoadState('load', { timeout: Math.min(timeout, SETTLE_TIMEOUT_MS) })
        .catch(() => {});

      // Halaman yang dirender JavaScript baru mengisi judulnya setelah skripnya
      // jalan. Sama seperti Instagram, dibaca berulang sampai isinya tidak
      // berubah lagi — kalau tidak, situs SPA selalu terbaca kosong.
      const raw = await extractWhenStable(page, extractPage, { rounds: 5, interval: 400 });

      return { raw, status: response ? response.status() : null, url: page.url() };
    }
  );
}

export async function scrapeWebsite(url, options = {}) {
  const {
    lang = 'id',
    country = 'ID',
    timeout = 45000,
    name = null,
    query = url,
    httpFallback = false
  } = options;

  let chain;

  try {
    chain = await resolveChain(url, { timeout, lang, country });
  } catch (error) {
    if (error instanceof ScrapeError) throw error;

    const reason = classifyFailure(describeFailure(error));

    // Domain telanjang dinaikkan ke https lebih dulu. Situs usaha kecil yang
    // masih http-only gagal di situ — bukan berarti tidak ada, jadi dicoba
    // sekali lagi lewat http sebelum divonis.
    if (httpFallback && ['tls_error', 'connection_refused', 'unreachable'].includes(reason)) {
      try {
        chain = await resolveChain(url.replace(/^https:/, 'http:'), { timeout, lang, country });
      } catch (retryError) {
        if (retryError instanceof ScrapeError) throw retryError;
        return settleFailure(query, url, classifyFailure(describeFailure(retryError)));
      }
    } else {
      return settleFailure(query, url, reason);
    }
  }

  const verdict = classifyStatus(chain.status);

  // Halaman mati tidak perlu dibuka di browser sama sekali.
  if (verdict.kind === 'unreadable') unreadable(verdict.reason, `Server menjawab ${chain.status}`);
  if (verdict.kind === 'dead') return notFound(query, url, verdict.reason);

  let rendered;

  try {
    rendered = await render(chain.finalUrl, { lang, country, timeout });
  } catch (error) {
    if (error instanceof ScrapeError) throw error;
    return settleFailure(query, url, classifyFailure(describeFailure(error)));
  }

  const { raw, status, url: renderedUrl } = rendered;

  if (looksParked(raw, renderedUrl)) return notFound(query, url, 'parked');

  const title = raw.title || raw.og_title || raw.heading;
  const finalHost = hostOf(renderedUrl);

  const site = {
    url,
    final_url: renderedUrl,
    // Pengalihan ke domain lain sering berarti domainnya sudah berpindah tangan
    // atau diarahkan ke marketplace. Dilaporkan, tidak divonis.
    redirected: chain.redirected || finalHost !== hostOf(url),
    status: status ?? chain.status,
    title,
    description: raw.description,
    parked: false,
    reason: null
  };

  const match = name
    ? matchScore(name, { name: title, address: finalHost, category: raw.description })
    : null;

  return {
    type: 'website',
    query,
    found: true,
    best_match: match,
    count: 1,
    reason: null,
    results: [{ ...site, match }]
  };
}

function settleFailure(query, url, reason) {
  if (reason === 'timeout' || reason === 'unreadable') {
    unreadable(reason, 'Halaman tidak dapat dibuka dalam batas waktu');
  }

  return notFound(query, url, reason);
}
