
export function extractList() {
  const clean = (value) => {
    if (typeof value !== 'string') return null;
    const stripped = value.replace(/[\uE000-\uF8FF]/g, ' ').replace(/\s+/g, ' ').trim();
    return stripped || null;
  };

  const text = (node) => clean(node && node.textContent);

  const pick = (root, selectors) => {
    for (const selector of selectors) {
      const found = text(root.querySelector(selector));
      if (found) return found;
    }
    return null;
  };

  const feed = document.querySelector('div[role="feed"]');
  const scope = feed || document.body;
  const anchors = Array.from(scope.querySelectorAll('a[href*="/maps/place/"]'));

  const seen = new Set();
  const results = [];

  for (const anchor of anchors) {
    const url = anchor.href;
    if (!url || seen.has(url)) continue;
    seen.add(url);

    const card = anchor.closest('.Nv2PK') || anchor.parentElement;
    if (!card) continue;

    const name =
      pick(card, ['.qBF1Pd', '.fontHeadlineSmall']) || clean(anchor.getAttribute('aria-label'));

    const lines = (card.innerText || '')
      .split('\n')
      .map(clean)
      .filter(Boolean);

    const statusPattern = /^(buka|tutup|open|clos|permanently|sementara)/i;
    const detailLine =
      lines.find(
        (line) => line.includes('·') && !/^\d/.test(line) && !statusPattern.test(line)
      ) || null;

    let category = null;
    let address = null;
    if (detailLine) {
      const parts = detailLine
        .split('·')
        .map((part) => part.trim())
        .filter(Boolean);

      category = parts[0] || null;
      address = parts.slice(1).join(' · ') || null;
    }

    const statusLine = lines.find((line) => statusPattern.test(line)) || null;

    results.push({
      name,
      url,
      rating_raw: pick(card, ['.MW4etd', 'span[role="img"][aria-label*="bintang"]']),
      reviews_raw: pick(card, ['.UY7F9', 'span[aria-label*="ulasan"]', 'span[aria-label*="review"]']),
      category,
      address,
      status: pick(card, ['.eXlrNe', '.fontBodyMedium span[style*="color"]']) || statusLine,
      sponsored: lines.some((line) => /^(bersponsor|sponsored)$/i.test(line))
    });
  }

  return results;
}

export function extractEndOfList() {
  const markers = Array.from(document.querySelectorAll('span.HlvSq, .PbZDve, .m6QErb .fontBodyMedium'));
  return markers.some((node) =>
    /akhir daftar|end of the list|end of list/i.test(node.textContent || '')
  );
}

export function extractPlace() {
  const clean = (value) => {
    if (typeof value !== 'string') return null;
    const stripped = value.replace(/[\uE000-\uF8FF]/g, ' ').replace(/\s+/g, ' ').trim();
    return stripped || null;
  };

  const text = (node) => clean(node && node.textContent);

  const pick = (selectors) => {
    for (const selector of selectors) {
      const found = text(document.querySelector(selector));
      if (found) return found;
    }
    return null;
  };

  const fromItem = (selector) => {
    const node = document.querySelector(selector);
    if (!node) return null;
    const label = node.getAttribute('aria-label') || node.textContent || '';
    const cleaned = label.includes(': ') ? label.slice(label.indexOf(': ') + 2) : label;
    return clean(cleaned);
  };

  const phoneNode = document.querySelector('button[data-item-id^="phone:tel:"]');
  const websiteNode = document.querySelector('a[data-item-id="authority"]');

  const ratingNode = document.querySelector('div.F7nice span[aria-hidden="true"]');
  const reviewsNode = document.querySelector(
    'div.F7nice span[aria-label*="ulasan"], div.F7nice span[aria-label*="review"]'
  );

  const hourRows = Array.from(document.querySelectorAll('table tr'))
    .map((row) => {
      const cells = Array.from(row.querySelectorAll('td'));
      if (cells.length < 2) return null;
      const day = text(cells[0]);
      const hours = clean((cells[1].innerText || '').replace(/\s*\n\s*/g, ', '));
      if (!day || !hours) return null;
      return { day, hours };
    })
    .filter(Boolean);

  const plusCode = fromItem('button[data-item-id="oloc"]');

  return {
    name: pick(['h1.DUwDvf', 'h1[class]']),
    category: pick(['button[jsaction*="category"]', '.DkEaL']),
    rating_raw: text(ratingNode),
    reviews_raw: reviewsNode ? reviewsNode.getAttribute('aria-label') : null,
    price_level: pick(['span[aria-label*="Rentang harga"]', 'span[aria-label*="Price range"]']),
    address: fromItem('button[data-item-id="address"]'),
    phone: phoneNode ? phoneNode.getAttribute('data-item-id').replace('phone:tel:', '') : null,
    website: websiteNode ? websiteNode.getAttribute('href') : null,
    plus_code: plusCode,
    status: pick(['.o0Sq6e', '.ZDu9vd span span']),
    description: pick(['.PYvSYb', '.WeS02d .fontBodyMedium']),
    opening_hours: hourRows,
    thumbnail:
      (document.querySelector('button[jsaction*="heroHeaderImage"] img') || {}).src ||
      (document.querySelector('.ZKCDEc img') || {}).src ||
      null
  };
}

export function extractProfile() {
  const clean = (value) => {
    if (typeof value !== 'string') return null;
    const trimmed = value.replace(/\s+/g, ' ').trim();
    return trimmed || null;
  };

  const meta = (selector, attribute = 'content') => {
    const node = document.querySelector(selector);
    return node ? clean(node.getAttribute(attribute)) : null;
  };

  const body = document.body ? document.body.innerText : '';
  const header = document.querySelector('header');

  const items = header ? Array.from(header.querySelectorAll('ul li')) : [];

  const titleOf = (node) => {
    if (!node) return null;
    const holder = node.querySelector('[title]');
    return holder ? clean(holder.getAttribute('title')) : null;
  };

  const externalLink = (root) => {
    if (!root) return null;
    const wrapped = root.querySelector('a[href*="l.instagram.com"]');
    if (wrapped) return wrapped;

    return (
      Array.from(root.querySelectorAll('a[href^="http"]')).find(
        (node) =>
          !/(^|\.)(instagram\.com|threads\.net|threads\.com|facebook\.com|meta\.com)$/i.test(
            node.hostname || ''
          )
      ) || null
    );
  };

  const bioLink = externalLink(header);

  return {
    og_title: meta('meta[property="og:title"]'),
    og_description: meta('meta[property="og:description"]'),
    og_url: meta('meta[property="og:url"]') || meta('link[rel="canonical"]', 'href'),
    meta_description: meta('meta[name="description"]'),
    followers_exact: titleOf(items[0]),
    stats_raw: items.slice(0, 3).map((item) => clean(item.innerText)),
    verified: Boolean(
      header && header.querySelector('svg[aria-label="Verified"], svg[aria-label="Terverifikasi"]')
    ),
    private: /This account is private|Akun ini privat/i.test(body),
    missing: /Profile isn't available|this page isn't available|Profile tidak tersedia|Halaman ini tidak tersedia/i.test(
      `${document.title} ${body.slice(0, 500)}`
    ),
    external_url: bioLink ? clean(bioLink.innerText) : null
  };
}

export function extractPage() {
  const clean = (value) => {
    if (typeof value !== 'string') return null;
    const trimmed = value.replace(/\s+/g, ' ').trim();
    return trimmed || null;
  };

  const meta = (selector, attribute = 'content') => {
    const node = document.querySelector(selector);
    return node ? clean(node.getAttribute(attribute)) : null;
  };

  const body = document.body ? document.body.innerText : '';

  const linkHosts = new Set();
  for (const anchor of document.querySelectorAll('a[href]')) {
    try {
      linkHosts.add(new URL(anchor.href, location.href).hostname.replace(/^www\./, ''));
    } catch {
    }
  }

  return {
    title: clean(document.title),
    heading: clean(document.querySelector('h1')?.textContent),
    description:
      meta('meta[name="description"]') || meta('meta[property="og:description"]'),
    og_title: meta('meta[property="og:title"]'),
    canonical: meta('link[rel="canonical"]', 'href'),
    text_length: body.replace(/\s+/g, ' ').trim().length,
    text_sample: clean(body.slice(0, 600)),
    link_hosts: Array.from(linkHosts).slice(0, 40)
  };
}
