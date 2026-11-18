// Caches the app so the page also opens without internet once it has been loaded before.
const CACHE = 'pptremote-v26';
const ASSETS = ['./', 'index.html', 'style.css', 'app.js', 'protocol.js', 'activity.js', 'storage.js', 'remotemic.js', 'manifest.webmanifest', 'favicon.png', 'icon-180.png', 'icon-192.png', 'icon-512.png', 'genart-ui.js',
  'genart/fonts.css', 'genart/tokens.css', 'genart/genart.css', 'genart/genart-dots.js',
  'genart/fonts/outfit-latin-wght-normal.woff2', 'genart/fonts/ibm-plex-mono-latin-400-normal.woff2', 'genart/fonts/ibm-plex-mono-latin-500-normal.woff2',
  'genart/logo/genart-wordmark-light.svg', 'genart/logo/made-by-genart-light.svg'];
const NETWORK_TIMEOUT_MS = 3000;

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS.map((a) => new Request(a, { cache: 'reload' })))).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

// Always asks the server whether a file changed (skipping the browser's own 10-minute cache).
// Network first (so updates arrive right away and files never mix versions); the saved copy is
// used when there is no internet or the network is too slow.
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin || url.pathname.includes('/api/')) return;
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const network = fetch(e.request, { cache: 'no-cache' }).then((res) => {
      if (res.ok) cache.put(e.request, res.clone());
      return res;
    });
    const timeout = new Promise((resolve) => setTimeout(resolve, NETWORK_TIMEOUT_MS));
    try {
      const res = await Promise.race([network, timeout]);
      if (res) return res;
    } catch { /* offline */ }
    const cached = await cache.match(e.request, { ignoreSearch: true });
    return cached || network;
  })());
});
