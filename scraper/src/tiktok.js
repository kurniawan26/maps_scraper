import { withPage } from './browser.js';
import { ScrapeError, matchScore, toSocialCount } from './util.js';

const SETTLE_TIMEOUT_MS = 20_000;

const DATA_SCRIPT_ID = '__UNIVERSAL_DATA_FOR_REHYDRATION__';

const MISSING_CODES = new Map([
  [10202, 'user_not_found'],
  [10221, 'user_banned_or_not_found']
]);

function profileUrl(username) {
  return `https://www.tiktok.com/@${encodeURIComponent(username)}`;
}

function extractUserDetail(scriptId) {
  const node = document.getElementById(scriptId);
  if (!node) return { present: false };

  try {
    const detail = JSON.parse(node.textContent).__DEFAULT_SCOPE__?.['webapp.user-detail'];
    if (!detail) return { present: true, detail: null };

    return {
      present: true,
      detail: {
        statusCode: detail.statusCode,
        statusMsg: detail.statusMsg || null,
        user: detail.userInfo?.user ?? null,
        stats: detail.userInfo?.stats ?? null
      }
    };
  } catch {
    return { present: true, detail: null };
  }
}

async function readUserDetail(page, settleMs) {
  const deadline = Date.now() + settleMs;
  let last = { present: false };

  while (Date.now() < deadline) {
    try {
      last = await page.evaluate(extractUserDetail, DATA_SCRIPT_ID);
      if (last.present) return last;
    } catch (error) {
      if (!/context was destroyed|frame was detached/i.test(error?.message || '')) throw error;
    }

    await page.waitForTimeout(500);
  }

  return last;
}

function normalizeProfile(user, stats) {
  const username = typeof user.uniqueId === 'string' ? user.uniqueId.toLowerCase() : null;

  return {
    username,
    full_name: user.nickname || null,
    bio: user.signature || null,
    external_url: user.bioLink?.link || null,
    verified: user.verified === true,
    private: user.privateAccount === true,
    followers: toSocialCount(stats?.followerCount),
    following: toSocialCount(stats?.followingCount),
    videos: toSocialCount(stats?.videoCount),
    likes: toSocialCount(stats?.heart),
    profile_url: username ? profileUrl(username) : null
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

function unreadable(message, code = 'tiktok_unreadable') {
  return new ScrapeError(message, { status: 503, code });
}

export async function scrapeTiktok(username, options = {}) {
  const { lang = 'en', country = 'US', timeout = 45000, name = null, query = username } = options;

  return withPage({ lang, country, timeout }, async (page) => {
    await page.goto(profileUrl(username), { waitUntil: 'domcontentloaded', timeout });

    const { present, detail } = await readUserDetail(page, Math.min(timeout, SETTLE_TIMEOUT_MS));

    if (!present) {
      throw unreadable('TikTok tidak menyajikan data profil (WAF/captcha)', 'tiktok_blocked');
    }

    if (!detail) throw unreadable('Data profil TikTok tidak dapat diurai');

    if (MISSING_CODES.has(detail.statusCode)) {
      return {
        type: 'profile',
        query,
        found: false,
        best_match: 0,
        count: 0,
        reason: MISSING_CODES.get(detail.statusCode),
        results: []
      };
    }

    if (detail.statusCode !== 0 || !detail.user?.uniqueId) {
      throw unreadable(
        `TikTok menjawab kode ${detail.statusCode}${detail.statusMsg ? ` (${detail.statusMsg})` : ''}`
      );
    }

    const profile = normalizeProfile(detail.user, detail.stats);
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
