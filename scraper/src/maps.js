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

const DETAIL_BUDGET_MS = Number(process.env.DETAIL_BUDGET_MS || 60_000);

const DETAIL_MIN_SLICE_MS = 2_000;

function detectBlock() {
  if (/\/sorry\//.test(location.pathname)) return true;
  if (document.querySelector('iframe[src*="recaptcha"], #captcha-form')) return true;
  const body = document.body ? document.body.innerText.slice(0, 2000) : '';
  return /unusual traffic|lalu lintas yang tidak biasa|not a robot|bukan robot/i.test(body);
}

async function assertNotBlocked(page) {
  const blocked = await page.evaluate(detectBlock).catch(() => false);
  if (blocked) {
    throw new ScrapeError('Google Maps meminta verifikasi captcha', {
      status: 503,
      code: 'maps_blocked'
    });
  }
}

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
  await page
    .waitForFunction(
      () => {
        const heading = document.querySelector('h1');
        if (heading && heading.textContent.trim()) return true;

        return location.pathname.includes('/maps/place//');
      },
      null,
      { timeout: Math.min(timeout, 12_000) }
    )
    .catch(() => {});

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

  await page.waitForFunction(() => /!3d-?\d/.test(location.href), null, { timeout: 5000 }).catch(() => {});

  const raw = await extractWhenStable(page, extractPlace);
  if (!raw.name) {
    await assertNotBlocked(page);
    throw new ScrapeError('Tempat tidak ditemukan atau halaman tidak dapat dibaca', {
      status: 404,
      code: 'place_not_found'
    });
  }

  return normalizePlace(raw, page.url());
}

export async function scrapePlace(url, options = {}) {
  const { lang = 'id', country = 'ID', timeout = 45000, name = null } = options;

  try {
    return await withPage({ lang, country, timeout }, async (page) => {
      const place = await readPlace(page, withLang(url, { lang, country }), { timeout });

      const match = name ? matchScore(name, place) : null;

      return {
        type: 'place',
        query: url,
        found: true,
        best_match: match,
        count: 1,
        results: [{ ...place, match }]
      };
    });
  } catch (error) {
    if (!(error instanceof ScrapeError) || error.code !== 'place_not_found') throw error;

    const fallbackQuery = queryFromMapsUrl(url);
    if (fallbackQuery) {
      const result = await scrapeSearch(fallbackQuery, options);
      return { ...result, query: url, resolved_from_url: fallbackQuery };
    }

    return { type: 'place', query: url, found: false, best_match: null, count: 0, results: [] };
  }
}

export async function scrapeSearch(query, options = {}) {
  const { lang = 'id', country = 'ID', timeout = 45000, detail = false, name = null } = options;
  const limit = clampInt(options.limit, { min: 1, max: 100, fallback: 20 });

  const scoreAgainst = name || query;

  return withPage({ lang, country, timeout }, async (page) => {
    await page.goto(searchUrl(query, { lang, country }), {
      waitUntil: 'domcontentloaded',
      timeout
    });

    const state = await waitForSearchState(page, timeout);

    if (state === 'blocked' || state === null) {
      await assertNotBlocked(page);
      throw new ScrapeError('Hasil pencarian Google Maps tidak terbaca dalam batas waktu', {
        status: 503,
        code: 'maps_unreadable'
      });
    }

    if (state === 'empty') {
      return { type: 'search', query, found: false, best_match: 0, count: 0, results: [] };
    }

    if (state !== 'feed') {
      const place = await readLoadedPlace(page, { timeout }).catch(() => null);
      if (!place) {
        return { type: 'search', query, found: false, best_match: 0, count: 0, results: [] };
      }

      const match = matchScore(scoreAgainst, place);
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

    results = results.map((place) => ({ ...place, match: matchScore(scoreAgainst, place) }));
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

async function waitForSearchState(page, timeout) {
  const handle = await page
    .waitForFunction(
      () => {
        if (/\/sorry\//.test(location.pathname)) return 'blocked';
        if (document.querySelector('iframe[src*="recaptcha"], #captcha-form')) return 'blocked';
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

  return extractWhenStable(page, extractList);
}

async function enrichWithDetail(results, { lang, country, timeout, deadline }) {
  return mapWithConcurrency(results, DETAIL_CONCURRENCY, async (item) => {
    const remaining = deadline - Date.now();

    if (remaining < DETAIL_MIN_SLICE_MS) return { ...item, detail_skipped: true };

    const slice = Math.min(timeout, remaining);

    try {
      const detailed = await withPage({ lang, country, timeout: slice }, (page) =>
        readPlace(page, withLang(item.maps_url, { lang, country }), { timeout: slice })
      );
      return { ...item, ...detailed };
    } catch {
      return { ...item, detail_error: true };
    }
  });
}
