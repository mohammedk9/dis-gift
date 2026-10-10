#!/usr/bin/env node
/* Bulk emoji removal. Inline SVG (works in static HTML + template literals);
   emoji inside text-only sinks (toast/textContent/data labels) are stripped. */
const fs = require('fs');
const path = require('path');

const SVG = (inner, w = 20, filled = 'currentColor') =>
  `<svg class="ico" width="${w}" height="${w}" viewBox="0 0 24 24" fill="${filled}" aria-hidden="true">${inner}</svg>`;

const GIFT = SVG('<path d="M9 2c-1.1 0-2 .9-2 2v2h10V4c0-1.1-.9-2-2-2h-6zM4 7v11c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V7H4zm3 4h2v5H7v-5zm4 0h2v5h-2v-5zm4 0h2v5h-2v-5z"/>', 20);
const GIFT_BIG = SVG('<path d="M9 2c-1.1 0-2 .9-2 2v2h10V4c0-1.1-.9-2-2-2h-6zM4 7v11c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V7H4zm3 4h2v5H7v-5zm4 0h2v5h-2v-5zm4 0h2v5h-2v-5z"/>', 40);
const STORE = SVG('<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="none" stroke="currentColor" stroke-width="2"/><polyline points="9 22 9 12 15 12 15 22" fill="none" stroke="currentColor" stroke-width="2"/>', 40);
const LIST40 = SVG('<rect x="4" y="3" width="16" height="18" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 8h8M8 12h8M8 16h5" fill="none" stroke="currentColor" stroke-width="2"/>', 40);
const INBOX40 = SVG('<path d="M22 12h-6l-2 3h-4l-2-3H2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M5.5 5.1 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.5-6.9A2 2 0 0 0 16.7 4H7.3a2 2 0 0 0-1.8 1.1z" fill="none" stroke="currentColor" stroke-width="2"/>', 40);

const R = [];
const add = (file, from, to) => R.push({ file, from, to });

/* --- brand-mark: inline SVG, works in static HTML + template literals --- */
for (const f of ['admin/index.html','admin/ledger.html','admin/offers.html','admin/orders.html',
  'admin/restaurants.html','admin/settings.html','admin/statements.html','checkout.html',
  'r/index.html','r/menu.html','r/offers.html','r/orders.html','r/profile.html','r/scan.html',
  'r/statement.html','register.html']) {
  add(f, '<span class="brand-mark">🎁</span>', `<span class="brand-mark">${GIFT}</span>`);
}

/* --- empty states --- */
add('admin/restaurants.html', '<div class="empty-ico">🏪</div>', `<div class="empty-ico">${STORE}</div>`);
add('r/menu.html', '<div class="empty-ico">📋</div>', `<div class="empty-ico">${LIST40}</div>`);
add('r/offers.html', '<div class="empty-ico">🎁</div>', `<div class="empty-ico">${GIFT_BIG}</div>`);
add('r/orders.html', '<div class="empty-ico">📭</div>', `<div class="empty-ico">${INBOX40}</div>`);

/* --- SQL message prefix: drop emoji --- */
for (const f of ['0007_whatsapp.sql','0008_delivery.sql','0009_consents.sql','0010_loyalty.sql']) {
  add(`supabase/migrations/${f}`, "v_out := '🎁 '", "v_out := ''");
}
add('supabase/migrations/0004_seed.sql', '-- ⚠️ ASSUMPTION:', '-- ASSUMPTION:');

module.exports = { R, add, GIFT, SVG };
