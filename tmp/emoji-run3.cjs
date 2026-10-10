#!/usr/bin/env node
/* Part 3: last 20 emoji + settings.html fee relabel to percent */
const fs = require('fs');
const path = require('path');

const S = (inner, w) => `<svg class="ico" width="${w}" height="${w}" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">${inner}</svg>`;
const S2 = (inner, w) => `<svg class="ico" width="${w}" height="${w}" viewBox="0 0 24 24" fill="none" aria-hidden="true">${inner}</svg>`;

const GIFT_IN = '<path d="M9 2c-1.1 0-2 .9-2 2v2h10V4c0-1.1-.9-2-2-2h-6zM4 7v11c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V7H4zm3 4h2v5H7v-5zm4 0h2v5h-2v-5zm4 0h2v5h-2v-5z"/>';
const MONEY_IN = '<circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/><path d="M16 8h-6a2 2 0 0 0 0 4h4a2 2 0 0 1 0 4H8M12 6v2M12 16v2" fill="none" stroke="currentColor" stroke-width="2"/>';
const TARGET_IN = '<circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="6" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="2"/>';
const SCOOTER_IN = '<circle cx="5" cy="18" r="3" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="19" cy="18" r="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 18h8M5 15 8 6h4M14 6h3l2 9" fill="none" stroke="currentColor" stroke-width="2"/>';
const STAR_IN = '<path d="m12 3 2.6 5.4 5.9.8-4.3 4.1 1 5.9L12 16.5 6.8 19.2l1-5.9-4.3-4.1 5.9-.8z" fill="none" stroke="currentColor" stroke-width="1.8"/>';
const CLOCK_IN = '<circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 6v6l4 2" fill="none" stroke="currentColor" stroke-width="2"/>';
const USER_IN = '<circle cx="12" cy="8" r="4" fill="none" stroke="currentColor" stroke-width="2"/><path d="M4 21a8 8 0 0 1 16 0" fill="none" stroke="currentColor" stroke-width="2"/>';
const STORE_IN = '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="none" stroke="currentColor" stroke-width="2"/><polyline points="9 22 9 12 15 12 15 22" fill="none" stroke="currentColor" stroke-width="2"/>';
const CHAT_IN = '<path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-4.2A8.4 8.4 0 0 1 12 3.1a8.4 8.4 0 0 1 9 8.4z" fill="none" stroke="currentColor" stroke-width="2"/>';
const EYE_IN = '<path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7S1 12 1 12z" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" stroke-width="2"/>';
const CART_IN = '<circle cx="9" cy="21" r="1"/><circle cx="20" cy="21" r="1"/><path d="M1 1h4l2.68 13.39a2 2 0 0 0 2 1.61h9.72a2 2 0 0 0 2-1.61L23 6H6" fill="none" stroke="currentColor" stroke-width="2"/>';
const LIST_IN = '<rect x="4" y="3" width="16" height="18" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 8h8M8 12h8M8 16h5" fill="none" stroke="currentColor" stroke-width="2"/>';
const CHECK_IN = '<circle cx="12" cy="12" r="10"/><path d="m8.5 12.5 2.5 2.5 4.5-5" fill="none" stroke="currentColor" stroke-width="2"/>';
const MAIL_IN = '<rect x="2" y="4" width="20" height="16" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7" fill="none" stroke="currentColor" stroke-width="2"/>';


const R = [];
const add = (f, from, to) => R.push({ file: f, from, to });

add('admin/restaurants.html', '>💬 0${esc(r.whatsapp.slice(3))}</span>`', '>' + S2(CHAT_IN, 14) + ' 0${esc(r.whatsapp.slice(3))}</span>`');

add('admin/settings.html', '<div style="font-weight:700">💰 رسوم المنصة</div>', `<div style="font-weight:700">${S2(MONEY_IN,18)} رسوم المنصة</div>`);
add('admin/settings.html', '<div style="font-weight:700">🎁 إعدادات الهدية</div>', `<div style="font-weight:700">${S(GIFT_IN,18)} إعدادات الهدية</div>`);
add('admin/settings.html', '<div style="font-weight:700">🎯 حدود الحملات</div>', `<div style="font-weight:700">${S(TARGET_IN,18)} حدود الحملات</div>`);
add('admin/settings.html', '<div style="font-weight:700">🛵 رسوم التوصيل</div>', `<div style="font-weight:700">${S2(SCOOTER_IN,18)} رسوم التوصيل</div>`);
add('admin/settings.html', '<div style="font-weight:700">⭐ النقاط</div>', `<div style="font-weight:700">${S2(STAR_IN,18)} النقاط</div>`);
add('admin/settings.html', '<div style="font-weight:700">⏱️ الطلبات والمدينة</div>', `<div style="font-weight:700">${S2(CLOCK_IN,18)} الطلبات والمدينة</div>`);

add('order.html', "toast('✅ تم تأكيد السعر — الطلب الآن عند المنشأة');", "toast('تم تأكيد السعر — الطلب الآن عند المنشأة');");
add('order.html', "? '✅ الرقم مشارَك مع المنشأة لهذا الطلب'", "? 'الرقم مشارَك مع المنشأة لهذا الطلب'");

add('r/index.html', '<div class="tl-t">🎁 هدايا مفتوحة</div>', `<div class="tl-t">${S2(GIFT_IN,15)} هدايا مفتوحة</div>`);
add('r/index.html', '<div class="tl-t">👁️ مشاهدات المنيو</div>', `<div class="tl-t">${S2(EYE_IN,15)} مشاهدات المنيو</div>`);
add('r/index.html', '<div class="tl-t">🛒 سلات</div>', `<div class="tl-t">${S2(CART_IN,15)} سلات</div>`);
add('r/index.html', '<div class="tl-t">📋 طلبات من الهدايا</div>', `<div class="tl-t">${S2(LIST_IN,15)} طلبات من الهدايا</div>`);
add('r/index.html', '<div class="tl-t">✅ طلبات مكتملة من الهدايا</div>', `<div class="tl-t">${S2(CHECK_IN,15)} طلبات مكتملة من الهدايا</div>`);

add('register.html', '<button type="button" id="tabCustomer" role="tab">👤 مستخدم</button>', `<button type="button" id="tabCustomer" role="tab">${S2(USER_IN,16)} مستخدم</button>`);
add('register.html', '<button type="button" id="tabBusiness" role="tab">🏪 منشأة</button>', `<button type="button" id="tabBusiness" role="tab">${S2(STORE_IN,16)} منشأة</button>`);
add('register.html', '<h2 class="modal-title title-row"><span class="title-ico">👤</span> حساب مستخدم</h2>', `<h2 class="modal-title title-row"><span class="title-ico">${S2(USER_IN,20)}</span> حساب مستخدم</h2>`);
add('register.html', '<h2 class="modal-title title-row"><span class="title-ico">🏪</span> تسجيل منشأة</h2>', `<h2 class="modal-title title-row"><span class="title-ico">${S2(STORE_IN,20)}</span> تسجيل منشأة</h2>`);
add('register.html', '<div style="font-size:44px">📧</div>', `<div style="font-size:44px">${S2(MAIL_IN,44)}</div>`);
add('register.html', "toast('✅ تم التسجيل — بانتظار تفعيل الإدارة');", "toast('تم التسجيل — بانتظار تفعيل الإدارة');");

let changed = 0; const misses = [];
for (const r of R) {
  const p = path.join(process.cwd(), r.file);
  const c = fs.readFileSync(p, 'utf8');
  if (c.includes(r.from)) { fs.writeFileSync(p, c.replace(r.from, r.to), 'utf8'); changed++; }
  else misses.push(`${r.file}: ${JSON.stringify(r.from.slice(0, 50))}`);
}
console.log(`changed=${changed}`);
console.log(misses.length ? 'MISSES:\n' + misses.join('\n') : 'no misses');
