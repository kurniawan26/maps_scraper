import { withPage } from './browser.js';
import { ScrapeError, matchScore, toSocialCount } from './util.js';

// TikTok memasang WAF di depan seluruh halamannya: permintaan HTTP polos
// dijawab 200 berisi tantangan JavaScript ("Please wait..."), untuk akun yang
// ada maupun yang tidak. Karena itu sumber ini memakai browser — tantangannya
// selesai sendiri, lalu halaman profil yang sesungguhnya dimuat.
//
// Setelah itu TikTok jauh lebih mudah dibaca daripada Instagram. Data profilnya
// sudah tertanam sebagai JSON di dalam HTML (#__UNIVERSAL_DATA_FOR_REHYDRATION__),
// lengkap dengan kode status, jadi tidak perlu menunggu DOM dirender maupun
// membaca teks yang berubah mengikuti bahasa.
const SETTLE_TIMEOUT_MS = 20_000;

const DATA_SCRIPT_ID = '__UNIVERSAL_DATA_FOR_REHYDRATION__';

// Kode status pada `webapp.user-detail`. Hanya kode yang terbukti berarti
// "akun tidak ada" yang dijawab found: false:
//
//   0      -> akun ada, userInfo terisi
//   10202  -> akun tidak ada
//   10221  -> akun diblokir TikTok — dan, terukur, juga yang dijawab untuk
//             username yang tidak pernah ada
//
// Kode lain belum pernah terlihat. Daripada menebak artinya, kode itu dijawab
// "tidak terbaca" supaya diulang — dan pesannya memuat kodenya, supaya
// kemunculannya bisa dipelajari dari log.
const MISSING_CODES = new Map([
  [10202, 'user_not_found'],
  [10221, 'user_banned_or_not_found']
]);

function profileUrl(username) {
  return `https://www.tiktok.com/@${encodeURIComponent(username)}`;
}

// Dijalankan di dalam halaman. Yang diambil hanya potongan user-detail, bukan
// seluruh JSON-nya — isinya bisa ratusan kilobyte.
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

// Halaman pertama bisa berupa tantangan WAF, yang memuat ulang dirinya setelah
// selesai. Menunggu dengan waitForFunction tidak cukup: navigasi itu
// menghancurkan konteks eksekusinya, dan penantiannya berhenti lebih awal
// tanpa data. Karena itu halaman dibaca berulang sampai datanya muncul.
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
    // `heartCount` meluap ke negatif pada akun besar (bilangan 32-bit);
    // `heart` tidak.
    likes: toSocialCount(stats?.heart),
    profile_url: username ? profileUrl(username) : null
  };
}

// Sama dengan Instagram: tanpa `name` pertanyaannya "apakah handle ini ada",
// dengan `name` pertanyaannya "apakah handle ini milik usaha bernama X".
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
  // 503, bukan 404: tidak tahu bukan berarti tidak ada. Status 5xx membuat
  // antrean validasi mengulangnya alih-alih memvonis barisnya.
  return new ScrapeError(message, { status: 503, code });
}

export async function scrapeTiktok(username, options = {}) {
  const { lang = 'en', country = 'US', timeout = 45000, name = null, query = username } = options;

  return withPage({ lang, country, timeout }, async (page) => {
    await page.goto(profileUrl(username), { waitUntil: 'domcontentloaded', timeout });

    const { present, detail } = await readUserDetail(page, Math.min(timeout, SETTLE_TIMEOUT_MS));

    if (!present) {
      // Tantangan WAF tidak selesai, atau TikTok menyajikan captcha. Keduanya
      // kegagalan kita, bukan jawaban tentang akunnya.
      throw unreadable('TikTok tidak menyajikan data profil (WAF/captcha)', 'tiktok_blocked');
    }

    if (!detail) throw unreadable('Data profil TikTok tidak dapat diurai');

    if (MISSING_CODES.has(detail.statusCode)) {
      // Akun yang tidak pernah ada dan akun yang diblokir tidak bisa dibedakan
      // dari luar — keduanya dijawab "tidak ditemukan", sama seperti Instagram.
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
