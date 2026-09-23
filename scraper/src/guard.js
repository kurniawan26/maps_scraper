import { lookup } from 'node:dns/promises';
import { isBlockedAddress, isIpLiteral } from './util.js';

// Hasil resolusi disimpan sebentar supaya penjagaan ini tidak memanggil DNS
// untuk tiap sub-resource halaman. Umurnya pendek dengan sengaja: domain yang
// tadinya publik bisa dipindahkan ke alamat internal, dan cache yang panjang
// membuat perubahan itu tak terlihat sampai proses di-restart.
const TTL_MS = 60_000;
const MAX_ENTRIES = 1_000;

const cache = new Map();

function remember(host, verdict) {
  // Map mempertahankan urutan sisip, jadi entri pertama adalah yang tertua.
  if (cache.size >= MAX_ENTRIES) cache.delete(cache.keys().next().value);
  cache.set(host, { verdict, expires: Date.now() + TTL_MS });
  return verdict;
}

/**
 * Memeriksa apakah sebuah host boleh dihubungi.
 *
 * Yang diperiksa adalah alamat hasil resolusi, bukan namanya: sebuah domain
 * publik bisa saja mengarah ke 127.0.0.1 atau ke 169.254.169.254, dan
 * pemeriksaan berbasis nama tidak akan melihatnya.
 *
 * Seluruh alamat host harus lolos. Domain yang mengarah ke beberapa alamat
 * sekaligus — satu publik, satu internal — ditolak seluruhnya, karena yang
 * menentukan alamat mana yang dipakai adalah resolver browser, bukan kita.
 */
export async function hostAllowed(host) {
  if (typeof host !== 'string' || !host) return false;

  const key = host.toLowerCase();
  const cached = cache.get(key);
  if (cached && cached.expires > Date.now()) return cached.verdict;

  if (isIpLiteral(key)) return remember(key, !isBlockedAddress(key));

  let addresses;
  try {
    addresses = await lookup(key, { all: true, verbatim: true });
  } catch {
    // Tidak dapat diresolusi. Dibiarkan lewat supaya browser yang menghasilkan
    // error aslinya (ERR_NAME_NOT_RESOLVED), yang kita terjemahkan jadi
    // "domain tidak ada" — bukan jadi "diblokir".
    return remember(key, true);
  }

  if (addresses.length === 0) return remember(key, true);

  return remember(key, !addresses.some((entry) => isBlockedAddress(entry.address)));
}

/** Dipakai test untuk memastikan hasil tidak terbawa antar-kasus. */
export function resetGuardCache() {
  cache.clear();
}
