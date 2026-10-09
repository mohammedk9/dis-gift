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
  // implicit: رابط تأكيد البريد يجب أن يعمل من أي متصفح أو تطبيق بريد.
  // pkce يطلب code_verifier محفوظاً في المتصفح الذي بدأ التسجيل، ويفشل من غيره.
  auth: { persistSession: true, autoRefreshToken: true, flowType: 'implicit' }
});

/* ---------- هوية العميل ----------
   الهوية هي حساب Supabase نفسه، لا متصفح هذا الجهاز:
   قاعدة البيانات تتجاهل ما يُرسَل في p_device وتقرأ auth.uid() من الجلسة،
   فالقيمة هنا للتوقيع فقط ولا تمنح العميل أي صلاحية ولا تُخزَّن في المتصفح. */
let actor = '00000000-0000-0000-0000-000000000000';

export async function currentUser() {
  const { data } = await sb.auth.getSession();
  return data.session?.user || null;
}

/** يُثبّت الهوية من الجلسة — يُستدعى مرة عند إقلاع كل صفحة محمية. */
export async function adoptIdentity() {
  const user = await currentUser();
  const next = user?.id || '00000000-0000-0000-0000-000000000000';
  /* تبديل الحساب على المتصفح نفسه: لا تُعرض بقايا الحساب السابق على غيره */
  const previous = sessionStorage.getItem('hg_actor_seen');
  if (previous && previous !== next) {
    for (const key of ['hg_gift', 'hg_cart', 'hg_name', 'hg_phone', 'hg_addr']) {
      try { localStorage.removeItem(key); } catch { /* تجاهل */ }
    }
  }
  try { sessionStorage.setItem('hg_actor_seen', next); } catch { /* تجاهل */ }
  actor = next;
  return user;
}

/** معرّف العميل المُرسَل مع النداءات. لا يمنح صلاحية: السيرفر يعتمد الجلسة. */
export const actorId = () => actor;

/* تنظيف بقايا نموذج الهوية القديم (المعرّف كان في المتصفح) */
for (const key of ['hg_device', 'hg_actor', 'hg_pending_restaurant']) {
  try { localStorage.removeItem(key); } catch { /* تجاهل */ }
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

/* ---------- gift cache ----------
   الكود لا يُخزَّن في المتصفح ولا يُعرض فيه: يظهر في صفحة الطلب لصاحبه فقط.
   (يُنقّى أيضاً ما خُزِّن قبل هذا التغيير حتى لا يبقى كود قديم في localStorage) */
const stripCode = g => {
  if (!g || typeof g !== 'object') return g;
  const copy = { ...g };
  delete copy.code;
  if (copy.gift && typeof copy.gift === 'object') {
    copy.gift = { ...copy.gift };
    delete copy.gift.code;
  }
  return copy;
};
export const getGift  = () => stripCode(JSON.parse(localStorage.getItem('hg_gift')  || 'null'));
export const setGift  = g  => localStorage.setItem('hg_gift', JSON.stringify(stripCode(g)));
export const clearGift = () => localStorage.removeItem('hg_gift');