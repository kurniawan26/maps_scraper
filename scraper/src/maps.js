import { extractWhenStable, withPage } from './browser.js';
import { extractList, extractEndOfList, extractPlace } from './extract.js';
import {
  ScrapeError,
  clampInt,
  coordsFromUrl,
  idsFromUrl,
  mapWithConcurrency,
  matchScore,
  queryFromMapsUrl,
  searchUrl,
  toCount,
  toFloat,
  withLang
} from './util.js';

const DETAIL_CONCURRENCY = Number(process.env.DETAIL_CONCURRENCY || 3);

// Dengan detail=true, lama satu permintaan tumbuh mengikuti jumlah hasil: tiap
// tempat dibuka sendiri, DETAIL_CONCURRENCY sekaligus. Untuk limit besar itu
// melewati batas waktu pemanggil, yang lalu memutus koneksi sementara sidecar
// tetap bekerja sia-sia. Anggaran di bawah ini membatasi seluruh fase detail;
// tempat yang tidak kebagian waktu dikembalikan dengan kolom kartunya saja.
//
// Nilainya dipakai MapsScraper.Maps.Client untuk menghitung batas waktu HTTP-nya,
// jadi harus sejalan dengan :detail_budget_ms di config Elixir.
const DETAIL_BUDGET_MS = Number(process.env.DETAIL_BUDGET_MS || 60_000);

// Di bawah ini membuka halaman baru hanya akan berujung timeout.
const DETAIL_MIN_SLICE_MS = 2_000;

function normalizeListItem(item) {
  const url = item.url;
  return {
    ...idsFromUrl(url),
    name: item.name,
    category: item.category,
    address: item.address,
    rating: toFloat(item.rating_raw),
    reviews_count: toCount(item.reviews_raw),
    status: item.status,
    sponsored: item.sponsored === true,
    ...coordsFromUrl(url),
    maps_url: url
  };
}

function normalizePlace(raw, url) {
  return {
    ...idsFromUrl(url),
    name: raw.name,
    category: raw.category,
    address: raw.address,
    phone: raw.phone,
    website: raw.website,
    rating: toFloat(raw.rating_raw),
    reviews_count: toCount(raw.reviews_raw),
    price_level: raw.price_level,
    plus_code: raw.plus_code,
    status: raw.status,
    description: raw.description,
    opening_hours: raw.opening_hours || [],
    thumbnail: raw.thumbnail,
    ...coordsFromUrl(url),
    maps_url: url
  };
}

async function readPlace(page, url, { timeout }) {
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout });
  return readLoadedPlace(page, { timeout });
}

async function readLoadedPlace(page, { timeout }) {
  // Judul tempat kerap berstatus hidden walau isinya sudah ada, jadi yang ditunggu
  // adalah teksnya terisi — bukan elemennya terlihat. Batas waktunya dipendekkan
  // supaya URL yang memang tidak menunjuk tempat gagal cepat, bukan setelah 45 detik.
  await page
    .waitForFunction(
      () => {
        const heading = document.querySelector('h1');
        if (heading && heading.textContent.trim()) return true;

        // Google mengosongkan segmen nama pada URL saat tidak ada tempat di baliknya,
        // mis. "/maps/place//@...". Mengenalinya membuat jalur cadangan tidak
        // perlu menunggu sampai batas waktu penuh.
        return location.pathname.includes('/maps/place//');
      },
      null,
      { timeout: Math.min(timeout, 12_000) }
    )
    .catch(() => {});

  // Judul muncul lebih dulu daripada blok rating dan daftar info, jadi tunggu sebentar
  // sampai salah satunya terisi. Tempat tanpa ulasan tidak boleh ikut tertahan di sini.
  await page
    .waitForFunction(
      () =>
        Boolean(
          document.querySelector('div.F7nice span[aria-label]') ||
            document.querySelector('button[data-item-id]')
        ),
      null,
      { timeout: 8000 }
    )
    .catch(() => {});

  // URL diperbarui Google setelah halaman siap; koordinat baru muncul di situ.
  await page.waitForFunction(() => /!3d-?\d/.test(location.href), null, { timeout: 5000 }).catch(() => {});

  const raw = await extractWhenStable(page, extractPlace);
  if (!raw.name) {
    throw new ScrapeError('Tempat tidak ditemukan atau halaman tidak dapat dibaca', {
      status: 404,
      code: 'place_not_found'
    });
  }

  return normalizePlace(raw, page.url());
}

export async function scrapePlace(url, options = {}) {
  const { lang = 'id', country = 'ID', timeout = 45000 } = options;

  try {
    return await withPage({ lang, country, timeout }, async (page) => {
      const place = await readPlace(page, withLang(url, { lang, country }), { timeout });
      // Skor kemiripan tidak berlaku di sini: URL menunjuk satu tempat secara pasti.
      return {
        type: 'place',
        query: url,
        found: true,
        best_match: null,
        count: 1,
        results: [{ ...place, match: null }]
      };
    });
  } catch (error) {
    if (!(error instanceof ScrapeError) || error.code !== 'place_not_found') throw error;

    // URL yang disalin dari bilah alamat sering kehilangan segmen `data=` sehingga
    // Google hanya membuka peta kosong. Nama tempat di URL masih bisa dicari.
    const fallbackQuery = queryFromMapsUrl(url);
    if (fallbackQuery) {
      const result = await scrapeSearch(fallbackQuery, options);
      return { ...result, query: url, resolved_from_url: fallbackQuery };
    }

    // Tidak ada tempat di balik URL itu — jawaban yang sah, bukan kegagalan.
    return { type: 'place', query: url, found: false, best_match: null, count: 0, results: [] };
  }
}

export async function scrapeSearch(query, options = {}) {
  const { lang = 'id', country = 'ID', timeout = 45000, detail = false } = options;
  const limit = clampInt(options.limit, { min: 1, max: 100, fallback: 20 });

  return withPage({ lang, country, timeout }, async (page) => {
    await page.goto(searchUrl(query, { lang, country }), {
      waitUntil: 'domcontentloaded',
      timeout
    });

    const state = await waitForSearchState(page, timeout);

    // Google menyatakan sendiri kalau tidak menemukan apa pun. Mengenalinya membuat
    // query yang memang tidak ada dijawab dalam hitungan detik, bukan menunggu timeout.
    if (state === 'empty') {
      return { type: 'search', query, found: false, best_match: 0, count: 0, results: [] };
    }

    // Pencarian dengan satu kecocokan kuat langsung menampilkan panel tempat, tanpa feed.
    // URL baru ditulis ulang Google beberapa detik kemudian, jadi yang dipercaya adalah DOM.
    if (state !== 'feed') {
      const place = await readLoadedPlace(page, { timeout }).catch(() => null);
      if (!place) {
        return { type: 'search', query, found: false, best_match: 0, count: 0, results: [] };
      }

      const match = matchScore(query, place);
      return {
        type: 'place',
        query,
        found: true,
        best_match: match,
        count: 1,
        results: [{ ...place, match }]
      };
    }

    const items = await collectFeed(page, limit);
    if (items.length === 0) {
      return { type: 'search', query, found: false, best_match: 0, count: 0, results: [] };
    }

    let results = items.slice(0, limit).map(normalizeListItem);

    if (detail) {
      results = await enrichWithDetail(results, {
        lang,
        country,
        timeout,
        deadline: Date.now() + DETAIL_BUDGET_MS
      });
    }

    results = results.map((place) => ({ ...place, match: matchScore(query, place) }));
    const bestMatch = results.some((place) => place.match === null)
      ? null
      : results.reduce((best, place) => Math.max(best, place.match), 0);

    return {
      type: 'search',
      query,
      found: results.length > 0,
      best_match: bestMatch,
      count: results.length,
      results
    };
  });
}

// Menunggu halaman pencarian menyatakan dirinya: daftar hasil, satu panel tempat,
// atau pernyataan tidak ada hasil. Mengembalikan null berarti "belum jelas" sehingga
// Playwright terus menjajaki sampai batas waktu.
async function waitForSearchState(page, timeout) {
  const handle = await page
    .waitForFunction(
      () => {
        if (document.querySelector('div[role="feed"] a[href*="/maps/place/"]')) return 'feed';

        const heading = document.querySelector('h1');
        if (heading && heading.textContent.trim()) return 'place';

        const body = document.body ? document.body.innerText : '';
        return /tidak dapat menemukan|tidak ditemukan|can't find|cannot find|did not match any/i.test(
          body
        )
          ? 'empty'
          : null;
      },
      null,
      { timeout }
    )
    .catch(() => null);

  return handle ? handle.jsonValue() : null;
}

// Feed Google memuat hasil secara bertahap, jadi harus di-scroll sampai
// cukup atau sampai daftarnya habis.
async function collectFeed(page, limit) {
  let items = await page.evaluate(extractList);
  let previousCount = items.length;
  let stagnantRounds = 0;

  while (items.length < limit && stagnantRounds < 3) {
    if (await page.evaluate(extractEndOfList)) break;

    await page.evaluate(() => {
      const feed = document.querySelector('div[role="feed"]');
      if (feed) feed.scrollBy(0, feed.scrollHeight);
    });
    await page.waitForTimeout(1200);

    items = await page.evaluate(extractList);
    if (items.length === previousCount) {
      stagnantRounds += 1;
    } else {
      stagnantRounds = 0;
      previousCount = items.length;
    }
  }

  // Jumlah kartu sudah pasti, tetapi isi tiap kartu masih bisa menyusul.
  return extractWhenStable(page, extractList);
}

// Kartu hasil hanya memuat sebagian kolom; detail lengkap butuh membuka tiap halaman.
async function enrichWithDetail(results, { lang, country, timeout, deadline }) {
  return mapWithConcurrency(results, DETAIL_CONCURRENCY, async (item) => {
    const remaining = deadline - Date.now();

    // Anggaran habis: sisa tempat dikembalikan apa adanya. Kolom dari kartu
    // hasil tetap terisi, hanya kolom yang butuh membuka halaman yang kosong.
    if (remaining < DETAIL_MIN_SLICE_MS) return { ...item, detail_skipped: true };

    const slice = Math.min(timeout, remaining);

    try {
      const detailed = await withPage({ lang, country, timeout: slice }, (page) =>
        readPlace(page, withLang(item.maps_url, { lang, country }), { timeout: slice })
      );
      return { ...item, ...detailed };
    } catch {
      // Satu tempat yang gagal tidak boleh menggagalkan seluruh pencarian.
      return { ...item, detail_error: true };
    }
  });
}
