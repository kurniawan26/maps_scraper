import { extractWhenStable, withPage } from './browser.js';
import { extractProfile } from './extract.js';
import { ScrapeError, matchScore, toCount, toSocialCount } from './util.js';

// Instagram memuat profilnya dari JavaScript. Menunggu `domcontentloaded` saja
// selalu menghasilkan halaman kosong, jadi yang ditunggu adalah salah satu dari
// dua penanda — profil ada, atau profil tidak ada.
const SETTLE_TIMEOUT_MS = 20_000;

// Halaman profil anonim menampilkan modal ajakan login di atas kontennya, tetapi
// itu hanya lapisan; data profil tetap ada di DOM. Yang benar-benar menghalangi
// adalah ketika Instagram mengalihkan ke halaman login — dan itu keadaan
// sementara yang harus diulang, bukan jawaban "akunnya tidak ada".
const LOGIN_PATH = /^\/accounts\/login/;

// Bahasa halaman ditentukan locale context dan header Accept-Language yang
// dipasang withPage, bukan parameter URL — Instagram mengabaikan ?hl=.
function profileUrl(username) {
  return `https://www.instagram.com/${encodeURIComponent(username)}/`;
}

// og:title berbentuk "Nama Lengkap (@username) • Instagram photos and videos".
// Bagian "(@username)" bentuknya sama di semua bahasa.
function parseOgTitle(value) {
  if (typeof value !== 'string') return { full_name: null, username: null };

  const match = value.match(/^(.*?)\s*\(@([A-Za-z0-9._]+)\)/);
  if (!match) return { full_name: null, username: null };

  return { full_name: match[1].trim() || null, username: match[2].toLowerCase() };
}

// Username hasil akhir diambil dari og:url, karena Instagram mengalihkan akun
// yang berganti nama tanpa memberi tahu lewat jalur lain.
function usernameFromUrl(value) {
  if (typeof value !== 'string') return null;
  try {
    const [first] = new URL(value).pathname.split('/').filter(Boolean);
    return first ? first.toLowerCase() : null;
  } catch {
    return null;
  }
}

// "710 Followers, 531 Following, 5 Posts - ..." — kata-katanya berubah mengikuti
// bahasa, tetapi urutannya tidak: pengikut, mengikuti, postingan. Jadi yang
// dibaca adalah urutan angkanya, bukan labelnya.
function statsFromDescription(value) {
  if (typeof value !== 'string') return [null, null, null];

  // Pola harus dimulai angka. Tanpa itu, koma pemisah antar-bagian ikut
  // tertangkap sebagai "angka" tersendiri dan seluruh urutannya bergeser —
  // jumlah postingan terbaca sebagai jumlah yang diikuti.
  const numbers = value.split(' - ')[0].match(/\d[\d.,]*\s*[KMBT]?/gi) || [];
  return [0, 1, 2].map((index) => toSocialCount(numbers[index]) ?? null);
}

// Teks di header ("513 following") lebih mutakhir daripada og:description, yang
// beberapa kali terlihat tertinggal. Tapi teks itu ikut dibulatkan pada angka
// besar ("268M followers"), jadi hanya dipakai kalau tanpa akhiran satuan.
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

// Seberapa yakin kita bahwa profil yang terbuka memang yang dimaksud pemanggil.
//
//   tanpa `name`  -> pertanyaannya cuma "apakah handle ini ada": 1 kalau
//                    Instagram menyajikan handle yang sama persis, 0 kalau ia
//                    mengalihkan kita ke akun lain.
//   dengan `name` -> pertanyaannya "apakah handle ini milik usaha bernama X",
//                    dan itu diukur dengan matchScore yang sama dengan Maps.
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

          // og:title ada di <head> dan muncul jauh lebih dulu daripada header
          // profil. Berhenti menunggu di situ membuat jumlah pengikut, lencana
          // terverifikasi, dan tautan bio terbaca dari halaman setengah jadi.
          if (!document.querySelector('meta[property="og:title"]')) return false;
          return Boolean(document.querySelector('header ul li'));
        },
        null,
        { timeout: Math.min(timeout, SETTLE_TIMEOUT_MS) }
      )
      .catch(() => {});

    // Header profil (jumlah pengikut, lencana terverifikasi, tautan bio) menyusul
    // setelah og:title ada di <head>. Membaca sekali di sini menangkap halaman
    // yang setengah jadi: lencananya belum muncul, angkanya belum terisi.
    const raw = await extractWhenStable(page, extractProfile);

    if (raw.missing) {
      // Instagram memakai halaman yang sama untuk username yang tidak pernah ada
      // dan untuk akun yang sudah dihapus atau dinonaktifkan. Keduanya tidak bisa
      // dibedakan dari luar, jadi keduanya dijawab "tidak ditemukan".
      return { type: 'profile', query, found: false, best_match: 0, count: 0, results: [] };
    }

    if (!raw.og_title) {
      const blocked = LOGIN_PATH.test(new URL(page.url()).pathname);

      throw new ScrapeError(
        blocked
          ? 'Instagram mengalihkan ke halaman login'
          : 'Profil tidak dapat dibaca dalam batas waktu',
        // 503, bukan 404: tidak tahu bukan berarti tidak ada. Status 5xx membuat
        // MapsScraper.Validation.Queue mengulangnya alih-alih memvonis barisnya.
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
