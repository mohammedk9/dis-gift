/* ============================================================
   ui.js — toast, modal, nav, guards
   ============================================================ */
import { sb, isConfigured, appUrl, adoptIdentity } from './core.js';

export const $  = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

/* ---------- أيقونات SVG (بدل الإيموجي) ----------
   مجموعة واحدة مركزية هنا، فتستخدمها كل الصفحات عبر icon('gift').
   الأيقونات ترث لون النص (currentColor) ولا تُقرأ لقارئ الشاشة. */
const ICON_PATHS = {
  gift:     '<path d="M9 2c-1.1 0-2 .9-2 2v2h10V4c0-1.1-.9-2-2-2h-6zM4 7v11c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V7H4zm3 4h2v5H7v-5zm4 0h2v5h-2v-5zm4 0h2v5h-2v-5z"/>',
  check:    '<circle cx="12" cy="12" r="10"/><path d="m8.5 12.5 2.5 2.5 4.5-5" fill="none" stroke="currentColor" stroke-width="2"/>',
  store:    '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="none" stroke="currentColor" stroke-width="2"/><polyline points="9 22 9 12 15 12 15 22" fill="none" stroke="currentColor" stroke-width="2"/>',
  list:     '<rect x="4" y="3" width="16" height="18" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 8h8M8 12h8M8 16h5" fill="none" stroke="currentColor" stroke-width="2"/>',
  alert:    '<path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/>',
  cart:     '<circle cx="9" cy="21" r="1"/><circle cx="20" cy="21" r="1"/><path d="M1 1h4l2.68 13.39a2 2 0 0 0 2 1.61h9.72a2 2 0 0 0 2-1.61L23 6H6" fill="none" stroke="currentColor" stroke-width="2"/>',
  pin:      '<path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="10" r="3" fill="none" stroke="currentColor" stroke-width="2"/>',
  user:     '<circle cx="12" cy="8" r="4" fill="none" stroke="currentColor" stroke-width="2"/><path d="M4 21a8 8 0 0 1 16 0" fill="none" stroke="currentColor" stroke-width="2"/>',
  money:    '<circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/><path d="M16 8h-6a2 2 0 0 0 0 4h4a2 2 0 0 1 0 4H8M12 6v2M12 16v2" fill="none" stroke="currentColor" stroke-width="2"/>',
  star:     '<path d="m12 3 2.6 5.4 5.9.8-4.3 4.1 1 5.9L12 16.5 6.8 19.2l1-5.9-4.3-4.1 5.9-.8z" fill="none" stroke="currentColor" stroke-width="1.8"/>',
  bell:     '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 0 1-3.4 0" fill="none" stroke="currentColor" stroke-width="2"/>',
  phone:    '<rect x="5" y="2" width="14" height="20" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 18h.01" stroke="currentColor" stroke-width="2"/>',
  mail:     '<rect x="2" y="4" width="20" height="16" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7" fill="none" stroke="currentColor" stroke-width="2"/>',
  eye:      '<path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7S1 12 1 12z" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" stroke-width="2"/>',
  utensils: '<path d="M3 2v7a3 3 0 0 0 3 3v10M6 2v6M18 2c-1.7 0-3 1.3-3 3v6h3v11" fill="none" stroke="currentColor" stroke-width="2"/>',
  coffee:   '<path d="M17 8h1a4 4 0 0 1 0 8h-1M3 8h14v9a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4zM6 2v3M10 2v3M14 2v3" fill="none" stroke="currentColor" stroke-width="2"/>',
  scissors: '<circle cx="6" cy="6" r="3" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="6" cy="18" r="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 4 8.1 15.9M14.5 14.5 20 20M8.1 8.1 12 12" fill="none" stroke="currentColor" stroke-width="2"/>',
  tool:     '<path d="M14.7 6.3a4 4 0 0 0 5 5l-9.4 9.4a2.8 2.8 0 0 1-4-4z" fill="none" stroke="currentColor" stroke-width="2"/><path d="M18 2l4 4-3 3-4-4z" fill="none" stroke="currentColor" stroke-width="2"/>',
  box:      '<path d="M21 8 12 3 3 8v8l9 5 9-5z" fill="none" stroke="currentColor" stroke-width="2"/><path d="M3 8l9 5 9-5M12 13v8" fill="none" stroke="currentColor" stroke-width="2"/>',
  chat:     '<path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-4.2A8.4 8.4 0 0 1 12 3.1a8.4 8.4 0 0 1 9 8.4z" fill="none" stroke="currentColor" stroke-width="2"/>',
  note:     '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" fill="none" stroke="currentColor" stroke-width="2"/><path d="M14 2v6h6M8 13h8M8 17h5" fill="none" stroke="currentColor" stroke-width="2"/>',
  bulb:     '<path d="M9 18h6M10 22h4M12 2a7 7 0 0 0-4 12.7c.6.5 1 1.3 1 2.3h6c0-1 .4-1.8 1-2.3A7 7 0 0 0 12 2z" fill="none" stroke="currentColor" stroke-width="2"/>',
  target:   '<circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="6" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="2"/>',
  scooter:  '<circle cx="5" cy="18" r="3" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="19" cy="18" r="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 18h8M5 15 8 6h4M14 6h3l2 9" fill="none" stroke="currentColor" stroke-width="2"/>',
  clock:    '<circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 6v6l4 2" fill="none" stroke="currentColor" stroke-width="2"/>',
  gear:     '<circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1" fill="none" stroke="currentColor" stroke-width="2"/>',
  inbox:    '<path d="M22 12h-6l-2 3h-4l-2-3H2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M5.5 5.1 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.5-6.9A2 2 0 0 0 16.7 4H7.3a2 2 0 0 0-1.8 1.1z" fill="none" stroke="currentColor" stroke-width="2"/>',
  cash:     '<rect x="2" y="6" width="20" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M6 10v4M18 10v4" fill="none" stroke="currentColor" stroke-width="2"/>'
};
/* icon('gift', 18) -> <svg ...> يرث لون النص عبر currentColor */
export function icon(name, size = 18) {
  const inner = ICON_PATHS[name];
  if (!inner) return '';
  return `<svg class="ico" width="${size}" height="${size}" viewBox="0 0 24 24" ` +
    `fill="currentColor" aria-hidden="true">${inner}</svg>`;
}


export function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

let toastBox;
export function toast(msg, ms = 2600) {
  toastBox ??= (() => {
    const d = document.createElement('div');
    d.className = 'toast';
    document.body.appendChild(d);
    return d;
  })();
  const t = document.createElement('div');
  t.textContent = msg;
  toastBox.appendChild(t);
  setTimeout(() => t.remove(), ms);
}

export function modal(html, { onOpen } = {}) {
  const bg = document.createElement('div');
  bg.className = 'modal-bg';
  bg.innerHTML = `<div class="modal">${html}</div>`;
  const close = () => bg.remove();
  bg.addEventListener('click', e => { if (e.target === bg) close(); });
  bg.querySelectorAll('[data-close]').forEach(b => b.onclick = close);
  document.body.appendChild(bg);
  onOpen?.(bg.querySelector('.modal'), close);
  return close;
}

export const confirmBox = (title, body, okLabel = 'تأكيد') => new Promise(res => {
  const close = modal(`
    <h3 class="modal-title">${esc(title)}</h3>
    <p class="muted small mb">${esc(body)}</p>
    <div class="flex" style="gap:8px">
      <button class="btn btn-ghost grow" data-close>إلغاء</button>
      <button class="btn btn-primary grow" id="mk-ok">${esc(okLabel)}</button>
    </div>`, {
    onOpen: (m, c) => {
      m.querySelector('#mk-ok').onclick = () => { c(); res(true); };
      m.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', () => res(false)));
    }
  });
  document.querySelector('.modal-bg:last-child')?.addEventListener('click', e => {
    if (e.target.classList.contains('modal-bg')) res(false);
  });
});

/* ---------- Config gate ---------- */
export function requireConfig() {
  if (isConfigured()) return true;
  const localDevelopment = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
  document.body.innerHTML = `<div class="container" style="padding-top:60px">
    <div class="card">
      <h2 class="page-title mb">${localDevelopment ? icon('gear', 20) + ' إعداد الاتصال مطلوب' : 'الخدمة غير جاهزة مؤقتاً'}</h2>
      <p class="muted small">${localDevelopment
        ? 'أدخل رابط مشروع Supabase والمفتاح العام (anon key) للتطوير المحلي.'
        : 'لم يتم تحميل إعدادات الاتصال بالمشروع بعد. لا يحتاج العميل إلى إدخال أي مفاتيح؛ أعد المحاولة بعد اكتمال النشر.'}</p>
      ${localDevelopment ? `<div class="field"><label class="label">Project URL</label>
        <input class="input" id="c-url" placeholder="https://xxxx.supabase.co"></div>
        <div class="field"><label class="label">Anon Key</label>
          <input class="input" id="c-key" placeholder="eyJhbGciOi..."></div>
        <button class="btn btn-primary btn-block" id="c-save">حفظ</button>
        <p class="hint">تُحفظ القيم محلياً في هذا المتصفح فقط.</p>` :
        '<button class="btn btn-primary btn-block" id="c-reload">إعادة المحاولة</button>'}
    </div></div>`;
  if (localDevelopment) {
    $('#c-save').onclick = () => {
      localStorage.setItem('hg_url', $('#c-url').value.trim());
      localStorage.setItem('hg_key', $('#c-key').value.trim());
      location.reload();
    };
  } else {
    $('#c-reload').onclick = () => location.reload();
  }
  return false;
}

/* ---------- auth guards ---------- */
export async function currentSession() {
  const { data } = await sb.auth.getSession();
  return data.session;
}

/** يحمي صفحات العميل: لا هدية ولا طلب ولا كود هدية بلا حساب. */
export async function guardCustomer() {
  const s = await currentSession();
  if (!s) {
    location.replace(appUrl('login.html') + '?mode=customer&next='
      + encodeURIComponent(location.pathname + location.search));
    return null;
  }
  await adoptIdentity();
  return s;
}

/** يحمي صفحات المنشأة: يتطلب جلسة + دور منشأة وربطاً بمنشأة */
export async function guardStaff({ allowAdmin = false } = {}) {
  const s = await currentSession();
  if (!s) { location.replace(appUrl('login.html') + '?next=' + encodeURIComponent(location.pathname + location.search)); return null; }
  const { data: prof } = await sb.from('profiles').select('role').eq('id', s.user.id).maybeSingle();
  let role = prof?.role;
  if (allowAdmin && (role === 'admin' || await isAdminUser(s.user.id))) {
    return { session: s, role: 'admin' };
  }
  if (role !== 'restaurant') { location.replace(appUrl('login.html') + '?err=not_restaurant'); return null; }
  const { data: staff } = await sb.from('restaurant_staff')
    .select('restaurant_id, role').eq('user_id', s.user.id).limit(1).maybeSingle();
  if (!staff) { location.replace(appUrl('login.html') + '?err=no_restaurant'); return null; }
  return { session: s, role: 'restaurant', restaurantId: staff.restaurant_id };
}

async function isAdminUser(uid) {
  const { data } = await sb.from('admin_users').select('user_id').eq('user_id', uid).maybeSingle();
  return !!data;
}

export async function guardAdmin() {
  const s = await currentSession();
  if (!s) { location.replace(appUrl('login.html') + '?next=' + encodeURIComponent(location.pathname + location.search)); return null; }
  if (!(await isAdminUser(s.user.id))) { location.replace(appUrl('r/')); return null; }
  return { session: s, role: 'admin' };
}

/* ---------- chrome ---------- */
export function customerNav(active = 'gift') {
  const items = [
    ['gift',   icon('gift', 22),   'الهدية',  appUrl('gift.html')],
    ['orders', icon('list', 22),   'طلباتي',  appUrl('orders.html')],
    ['notif',  icon('bell', 22),   'التنبيهات', appUrl('notices.html')],
    ['more',   icon('user', 22),   'المزيد',   appUrl('account.html')],
  ];
  return `<nav class="bnav">${items.map(([k, ico, lbl, href]) =>
    `<a href="${href}" class="${active === k ? 'active' : ''}">
       <span class="bnav-ico">${ico}</span>${lbl}</a>`).join('')}</nav>`;
}

export function staffNav(active, links) {
  return `<div class="tabs" style="margin:14px 0 0">${links.map(([k, lbl, href]) =>
    `<a class="tab ${active === k ? 'active' : ''}" href="${href}">${esc(lbl)}</a>`).join('')}</div>`;
}

/* ---------- PWA: install + service worker ---------- */
export function initPWA() {
  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    navigator.serviceWorker.register(appUrl('sw.js')).catch(() => {});
  } else if ('serviceWorker' in navigator && location.hostname === 'localhost') {
    navigator.serviceWorker.register(appUrl('sw.js')).catch(() => {});
  }

  let deferred = null;
  window.addEventListener('beforeinstallprompt', e => {
    e.preventDefault();
    deferred = e;
    if (localStorage.getItem('hg_pwa_dismissed')) return;
    // زر تثبيت هادئ أسفل الصفحة
    const bar = document.createElement('div');
    bar.className = 'pwa-bar';
    bar.innerHTML = `<span class="grow">${icon('phone', 18)} ثبّت «هدية» كتطبيق على جهازك</span>
      <button class="btn btn-sm btn-primary" id="pwa-yes">تثبيت</button>
      <button class="btn btn-sm btn-ghost" id="pwa-no">×</button>`;
    document.body.appendChild(bar);
    bar.querySelector('#pwa-yes').onclick = async () => {
      bar.remove();
      deferred.prompt();
      await deferred.userChoice;
      deferred = null;
    };
    bar.querySelector('#pwa-no').onclick = () => {
      bar.remove();
      localStorage.setItem('hg_pwa_dismissed', '1');
    };
    setTimeout(() => bar.remove(), 20000);
  });
}

export function header(title, back = appUrl('')) {
  return `<header class="nav"><div class="container nav-inner">
    <a class="brand" href="${back}">
      <span class="brand-mark">${icon('gift', 20)}</span>
      <span><span class="brand-name">هدية</span><br><span class="brand-sub">اكتشف · اطلب</span></span>
    </a>
    <span class="nav-spacer"></span>
    <span class="small muted">${esc(title)}</span>
  </div></header>`;
}