import { extractWhenStable, withPage } from './browser.js';
import { extractProfile } from './extract.js';
import { ScrapeError, matchScore, toCount, toSocialCount } from './util.js';

const SETTLE_TIMEOUT_MS = 20_000;

const LOGIN_PATH = /^\/accounts\/login/;

function profileUrl(username) {
  return `https://www.instagram.com/${encodeURIComponent(username)}/`;
}

function parseOgTitle(value) {
  if (typeof value !== 'string') return { full_name: null, username: null };

  const match = value.match(/^(.*?)\s*\(@([A-Za-z0-9._]+)\)/);
  if (!match) return { full_name: null, username: null };

  return { full_name: match[1].trim() || null, username: match[2].toLowerCase() };
}

function usernameFromUrl(value) {
  if (typeof value !== 'string') return null;
  try {
    const [first] = new URL(value).pathname.split('/').filter(Boolean);
    return first ? first.toLowerCase() : null;
  } catch {
    return null;
  }
}

function statsFromDescription(value) {
  if (typeof value !== 'string') return [null, null, null];

  const numbers = value.split(' - ')[0].match(/\d[\d.,]*\s*[KMBT]?/gi) || [];
  return [0, 1, 2].map((index) => toSocialCount(numbers[index]) ?? null);
}

function exactFromStatLine(value) {
  if (typeof value !== 'string') return null;
  if (/\d\s*(k|rb|m|jt|b|t)\b/i.test(value)) return null;
  return toCount(value);
}

function parseBio(metaDescription) {
  if (typeof metaDescription !== 'string') return null;
  const match = metaDescription.match(/Instagram:\s*"([\s\S]*)"\s*$/);
  if (!match) return null;
  return match[1].trim() || null;
}

function normalizeProfile(raw) {
  const fromTitle = parseOgTitle(raw.og_title);
  const username = usernameFromUrl(raw.og_url) || fromTitle.username;
  const [descFollowers, descFollowing, descPosts] = statsFromDescription(raw.og_description);

  return {
    username,
    full_name: fromTitle.full_name,
    bio: parseBio(raw.meta_description),
    external_url: raw.external_url,
    verified: raw.verified === true,
    private: raw.private === true,
    followers: toSocialCount(raw.followers_exact) ?? descFollowers,
    following: exactFromStatLine(raw.stats_raw?.[1]) ?? descFollowing,
    posts: descPosts,
    profile_url: username ? `https://www.instagram.com/${username}/` : null
  };
}

function profileMatch(requested, profile, name) {
  if (name) {
    return matchScore(name, {
      name: profile.full_name,
      address: profile.username,
      category: profile.bio
    });
  }

  if (!profile.username) return 0;
  return profile.username === requested.toLowerCase() ? 1 : 0;
}

export async function scrapeProfile(username, options = {}) {
  const { lang = 'en', country = 'US', timeout = 45000, name = null, query = username } = options;

  return withPage({ lang, country, timeout }, async (page) => {
    await page.goto(profileUrl(username), {
      waitUntil: 'domcontentloaded',
      timeout
    });

    await page
      .waitForFunction(
        () => {
          const missing =
            /Profile isn't available|this page isn't available|Profile tidak tersedia/i.test(
              `${document.title} ${document.body ? document.body.innerText.slice(0, 500) : ''}`
            );
          if (missing) return true;

          if (!document.querySelector('meta[property="og:title"]')) return false;
          return Boolean(document.querySelector('header ul li'));
        },
        null,
        { timeout: Math.min(timeout, SETTLE_TIMEOUT_MS) }
      )
      .catch(() => {});

    const raw = await extractWhenStable(page, extractProfile);

    if (raw.missing) {
      return { type: 'profile', query, found: false, best_match: 0, count: 0, results: [] };
    }

    if (!raw.og_title) {
      const blocked = LOGIN_PATH.test(new URL(page.url()).pathname);

      throw new ScrapeError(
        blocked
          ? 'Instagram mengalihkan ke halaman login'
          : 'Profil tidak dapat dibaca dalam batas waktu',
        { status: 503, code: blocked ? 'instagram_blocked' : 'instagram_unreadable' }
      );
    }

    const profile = normalizeProfile(raw);
    const match = profileMatch(username, profile, name);

    return {
      type: 'profile',
      query,
      found: true,
      best_match: match,
      count: 1,
      results: [{ ...profile, match }]
    };
  });
}
