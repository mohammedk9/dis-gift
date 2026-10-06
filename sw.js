/* ============================================================
   sw.js — Service Worker بسيط (PWA)
   لا يخزّن طلبات Supabase إطلاقاً (بيانات حية)
   ============================================================ */
const BASE = new URL('./', self.location).pathname;
const CACHE = 'hadiya-v2';
const SHELL = [
  'index.html', 'gift.html', 'orders.html', 'account.html',
  'assets/css/app.css', 'assets/js/core.js', 'assets/js/ui.js',
  'assets/js/vendor/supabase.js',
  'assets/icon.svg', 'manifest.webmanifest'
].map(path => new URL(path, self.location).pathname);

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).catch(() => {}));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks =>
    Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // لا نتدخل في أي طلب شبكة (Supabase / صور خارجية)
  if (e.request.method !== 'GET') return;
  if (url.hostname.includes('supabase') || url.origin !== location.origin) return;
  // Runtime configuration is generated during deployment and must never be
  // served from a stale offline cache.
  if (url.pathname.endsWith('/assets/js/runtime-config.js')) return;

  e.respondWith(
    caches.match(e.request).then(hit => hit || fetch(e.request).then(res => {
      if (res.ok && SHELL.includes(url.pathname)) {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy));
      }
      return res;
    }).catch(() => caches.match(BASE + 'index.html')))
  );
});