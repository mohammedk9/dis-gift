/* ============================================================
   core.js — Supabase client + config + helpers
   يُحمَّل عبر <script type="module"> بعد vendor/supabase.js
   ============================================================ */
const { createClient } = window.supabase;

const runtime = window.__HADIYA_CONFIG__ || {};
const PLACEHOLDER_URL = 'https://YOUR-PROJECT.supabase.co';
const PLACEHOLDER_KEY = 'YOUR-ANON-KEY';
const validUrl = value => {
  try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && !!url.hostname;
  } catch { return false; }
};
const validKey = value => typeof value === 'string' && value.length > 20 &&
  !value.includes('YOUR-ANON-KEY');
const localDevelopment = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
const runtimeUrl = validUrl(runtime.supabaseUrl) ? runtime.supabaseUrl.trim() : '';
const runtimeKey = validKey(runtime.supabaseAnonKey) ? runtime.supabaseAnonKey.trim() : '';
const storedUrl = localStorage.getItem('hg_url')?.trim();
const storedKey = localStorage.getItem('hg_key')?.trim();

export const CFG = {
  // The deployed project config must win over browser-local development values.
  // Otherwise a stale localStorage value can break the site in one browser only.
  url:  runtimeUrl || (localDevelopment && validUrl(storedUrl) ? storedUrl : PLACEHOLDER_URL),
  anon: runtimeKey || (localDevelopment && validKey(storedKey) ? storedKey : PLACEHOLDER_KEY),
};

export const isConfigured = () =>
  validUrl(CFG.url) && validKey(CFG.anon);

/* Works both at the domain root and under a GitHub Pages project path. */
export const APP_ROOT = new URL('../../', import.meta.url);
export function appUrl(path = '') {
  return new URL(String(path).replace(/^\/+/, ''), APP_ROOT).pathname;
}

export const sb = createClient(CFG.url, CFG.anon, {
  auth: { persistSession: true, autoRefreshToken: true, flowType: 'pkce' }
});

/* ---------- device id: معرّف العميل في MVP (لا تسجيل) ---------- */
export function deviceId() {
  let d = localStorage.getItem('hg_device');
  if (!d) {
    d = (crypto.randomUUID ? crypto.randomUUID()
      : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
          const r = Math.random() * 16 | 0;
          return (c === 'x' ? r : (r & 3 | 8)).toString(16);
        }));
    localStorage.setItem('hg_device', d);
  }
  return d;
}

/* ---------- area ---------- */
export function areaId() {
  const v = localStorage.getItem('hg_area');
  return v ? Number(v) : null;
}
export function setArea(id) { localStorage.setItem('hg_area', id || ''); }

/* ---------- cart (device-local) ---------- */
const CART_KEY = 'hg_cart';
export function getCart() {
  try { return JSON.parse(localStorage.getItem(CART_KEY)) || []; }
  catch { return []; }
}
export function setCart(items) {
  localStorage.setItem(CART_KEY, JSON.stringify(items));
  window.dispatchEvent(new CustomEvent('hg:cart'));
}
export function addToCart(item) {
  const c = getCart();
  const found = c.find(x => x.id === item.id);
  if (found) found.qty += 1; else c.push({ ...item, qty: 1 });
  setCart(c);
}
export function setQty(id, qty) {
  let c = getCart();
  if (qty <= 0) c = c.filter(x => x.id !== id);
  else { const f = c.find(x => x.id === id); if (f) f.qty = qty; }
  setCart(c);
}
export function clearCart() { setCart([]); }
export function cartTotal() {
  return getCart().reduce((s, i) => s + (Number(i.price) * i.qty), 0);
}

/* ---------- formatting ---------- */
export const sar = n => `${Number(n || 0).toFixed(2)} ر.س`;
export const pct = n => `${(Number(n || 0) * 100).toFixed(1)}%`;
export function dt(ts) {
  if (!ts) return '';
  return new Date(ts).toLocaleString('ar-SA', {
    day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit'
  });
}
export const STATUS_AR = {
  new: 'جديد', accepted: 'مقبول', preparing: 'قيد التجهيز', ready: 'جاهز',
  completed: 'مكتمل', cancelled: 'ملغي', no_show: 'لم يحضر'
};
export const STATUS_CLASS = {
  new: 'badge-blue', accepted: 'badge-orange', preparing: 'badge-orange',
  ready: 'badge-green', completed: 'badge-green', cancelled: 'badge-red', no_show: 'badge-red'
};
export const RSTATUS_AR = {
  pending: 'بانتظار التفعيل', active: 'نشط', suspended: 'موقوف', hidden: 'مخفي'
};

/* ---------- gift cache ---------- */
export const getGift  = () => JSON.parse(localStorage.getItem('hg_gift')  || 'null');
export const setGift  = g  => localStorage.setItem('hg_gift', JSON.stringify(g));
export const clearGift = () => localStorage.removeItem('hg_gift');