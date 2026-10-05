/* ============================================================
   core.js — Supabase client + config + helpers
   يُحمَّل عبر <script type="module"> بعد vendor/supabase.js
   ============================================================ */
const { createClient } = window.supabase;

export const CFG = {
  url:  localStorage.getItem('hg_url')  || 'https://YOUR-PROJECT.supabase.co',
  anon: localStorage.getItem('hg_key') || 'YOUR-ANON-KEY',
};

export const isConfigured = () =>
  !CFG.url.includes('YOUR-PROJECT') && !CFG.anon.includes('YOUR-ANON-KEY');

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