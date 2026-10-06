/* ============================================================
   ui.js — toast, modal, nav, guards
   ============================================================ */
import { sb, isConfigured, appUrl } from './core.js';

export const $  = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

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
  document.body.innerHTML = `<div class="container" style="padding-top:60px">
    <div class="card">
      <h2 class="page-title mb">⚙️ إعداد الاتصال مطلوب</h2>
      <p class="muted small">أدخل رابط مشروع Supabase والمفتاح العام (anon key).</p>
      <div class="field"><label class="label">Project URL</label>
        <input class="input" id="c-url" placeholder="https://xxxx.supabase.co"></div>
      <div class="field"><label class="label">Anon Key</label>
        <input class="input" id="c-key" placeholder="eyJhbGciOi..."></div>
      <button class="btn btn-primary btn-block" id="c-save">حفظ</button>
      <p class="hint">تُحفظ القيم محلياً في هذا المتصفح فقط.</p>
    </div></div>`;
  $('#c-save').onclick = () => {
    localStorage.setItem('hg_url', $('#c-url').value.trim());
    localStorage.setItem('hg_key', $('#c-key').value.trim());
    location.reload();
  };
  return false;
}

/* ---------- auth guards ---------- */
export async function currentSession() {
  const { data } = await sb.auth.getSession();
  return data.session;
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
    ['gift',   '🎁', 'الهدية',  appUrl('gift.html')],
    ['orders', '📋', 'طلباتي',  appUrl('orders.html')],
    ['notif',  '🔔', 'التنبيهات', appUrl('notices.html')],
    ['more',   '⋯', 'المزيد',   appUrl('account.html')],
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
    bar.innerHTML = `<span class="grow">📲 ثبّت «هدية» كتطبيق على جهازك</span>
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
      <span class="brand-mark">🎁</span>
      <span><span class="brand-name">هدية</span><br><span class="brand-sub">اكتشف · اطلب</span></span>
    </a>
    <span class="nav-spacer"></span>
    <span class="small muted">${esc(title)}</span>
  </div></header>`;
}