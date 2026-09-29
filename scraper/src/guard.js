import { lookup } from 'node:dns/promises';
import { isBlockedAddress, isIpLiteral } from './util.js';

const TTL_MS = 60_000;
const MAX_ENTRIES = 1_000;

const cache = new Map();

function remember(host, verdict) {
  if (cache.size >= MAX_ENTRIES) cache.delete(cache.keys().next().value);
  cache.set(host, { verdict, expires: Date.now() + TTL_MS });
  return verdict;
}

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
    return remember(key, true);
  }

  if (addresses.length === 0) return remember(key, true);

  return remember(key, !addresses.some((entry) => isBlockedAddress(entry.address)));
}

export function resetGuardCache() {
  cache.clear();
}
