/* ============================================================================
 *  واصل الإمارات — Wasel UAE
 *  Service Worker — التخزين المؤقت والعمل دون اتصال
 *  الإصدار: 1.0.0
 * ========================================================================== */

const CACHE_VERSION = 'wasel-v1.0.0';
const STATIC_CACHE = `${CACHE_VERSION}-static`;
const RUNTIME_CACHE = `${CACHE_VERSION}-runtime`;

// الموارد الأساسية التي تُخزّن عند التثبيت (التطبيق نفسه + المكتبات الحرجة)
const PRECACHE_URLS = [
  './',
  './wasel-uae-app.html',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  // مكتبات CDN (تُخزّن لكي يعمل التطبيق دون اتصال جزئياً)
  'https://cdn.tailwindcss.com',
  'https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css',
  'https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js',
];

// الاستراتيجية: الشبكة أولاً للطلبات الحية، التخزين أولاً للموارد الثابتة
const NETWORK_FIRST_PATTERNS = [
  /supabase\.co/,           // كل طلبات Supabase (REST + Realtime)
  /mapbox\.com/,            // خرائط Mapbox
  /api\./,                  // أي API خارجي
];

const CACHE_FIRST_PATTERNS = [
  /\.css$/,
  /\.js$/,
  /\.png$/,
  /\.jpg$/,
  /\.svg$/,
  /font-awesome/,
  /tailwindcss/,
  /chart\.js/,
  /supabase-js/,
];

// ---------------------------------------------------------------------------
// التثبيت: خزّن الموارد الأساسية مسبقاً
// ---------------------------------------------------------------------------
self.addEventListener('install', (event) => {
  console.log('[SW] تثبيت الإصدار', CACHE_VERSION);
  event.waitUntil(
    caches.open(STATIC_CACHE)
      .then((cache) => cache.addAll(PRECACHE_URLS))
      .then(() => self.skipWaiting())
      .catch((err) => console.warn('[SW] فشل التخزين المسبق لبعض الموارد:', err))
  );
});

// ---------------------------------------------------------------------------
// التفعيل: احذف الكاشات القديمة
// ---------------------------------------------------------------------------
self.addEventListener('activate', (event) => {
  console.log('[SW] تفعيل الإصدار', CACHE_VERSION);
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys
          .filter((key) => key.startsWith('wasel-') && key !== STATIC_CACHE && key !== RUNTIME_CACHE)
          .map((key) => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

// ---------------------------------------------------------------------------
// اعتراض الطلبات: اختر الاستراتيجية المناسبة
// ---------------------------------------------------------------------------
self.addEventListener('fetch', (event) => {
  const { request } = event;

  // تجاهل الطلبات غير GET (POST/PATCH/DELETE تذهب للشبكة مباشرة)
  if (request.method !== 'GET') return;

  // تجاهل طلبات Supabase Realtime (WebSocket)
  if (request.url.includes('/realtime/')) return;

  const url = new URL(request.url);

  // لا نintercept طلبات المصادقة أو الـ Realtime
  if (NETWORK_FIRST_PATTERNS.some((p) => p.test(url.href))) {
    event.respondWith(networkFirst(request));
    return;
  }

  if (CACHE_FIRST_PATTERNS.some((p) => p.test(url.href))) {
    event.respondWith(cacheFirst(request));
    return;
  }

  // افتراضي: الشبكة أولاً، ثم الكاش
  event.respondWith(networkFirst(request));
});

// ---------------------------------------------------------------------------
// استراتيجية: الكاش أولاً (للموارد الثابتة)
// ---------------------------------------------------------------------------
async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) {
    // حدّث الكاش في الخلفية
    fetch(request).then((response) => {
      if (response && response.status === 200) {
        caches.open(STATIC_CACHE).then((cache) => cache.put(request, response));
      }
    }).catch(() => {});
    return cached;
  }
  try {
    const response = await fetch(request);
    if (response && response.status === 200) {
      const cache = await caches.open(STATIC_CACHE);
      cache.put(request, response.clone());
    }
    return response;
  } catch (err) {
    // لا يوجد كاش ولا شبكة — صفحة بديلة بسيطة
    return new Response(
      '<html><body style="font-family:sans-serif;text-align:center;padding:40px;direction:rtl"><h2>لا يوجد اتصال بالإنترنت</h2><p>يحتاج هذا المحتوى إلى اتصال لتحميله لأول مرة.</p></body></html>',
      { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
    );
  }
}

// ---------------------------------------------------------------------------
// استراتيجية: الشبكة أولاً (لبيانات Supabase و Mapbox)
// ---------------------------------------------------------------------------
async function networkFirst(request) {
  try {
    const response = await fetch(request);
    if (response && response.status === 200 && response.type === 'basic') {
      const cache = await caches.open(RUNTIME_CACHE);
      cache.put(request, response.clone());
    }
    return response;
  } catch (err) {
    const cached = await caches.match(request);
    if (cached) {
      return cached;
    }
    throw err;
  }
}

// ---------------------------------------------------------------------------
// الرسائل: السماح للصفحة بطلب تحديث الكاش
// ---------------------------------------------------------------------------
self.addEventListener('message', (event) => {
  if (event.data === 'SKIP_WAITING') {
    self.skipWaiting();
  } else if (event.data === 'CLEAR_CACHE') {
    caches.keys().then((keys) => Promise.all(keys.map((k) => caches.delete(k))));
  }
});
