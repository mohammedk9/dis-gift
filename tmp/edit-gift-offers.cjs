/* CRLF-safe edit of gift.html:
   1. Add import for loadPublicOffers
   2. Replace the hard guardCustomer() gate at page load with optional session
   3. Add offer rendering to stageClosed()
   4. Move guardCustomer() call to the open() function before open_daily_gift RPC
*/
const fs = require('fs');
const p = 'gift.html';
let s = fs.readFileSync(p, 'utf8');
const before = s.length;

function replaceOnce(haystack, from, to, label) {
  const i = haystack.indexOf(from);
  if (i === -1) throw new Error('anchor not found: ' + label);
  if (haystack.indexOf(from, i + 1) !== -1) throw new Error('anchor not unique: ' + label);
  return haystack.slice(0, i) + to + haystack.slice(i + from.length);
}

// 1) Add import for loadPublicOffers
s = replaceOnce(
  s,
  "import { $, esc, toast, modal, requireConfig, customerNav, initPWA, guardCustomer } from './assets/js/ui.js';",
  "import { $, esc, toast, modal, requireConfig, customerNav, initPWA, guardCustomer } from './assets/js/ui.js';\r\n" +
  "import { loadPublicOffers } from './assets/js/public-offers.js';",
  'ui import'
);

// 2) Replace the hard guard + setup with optional identity + setup
const oldGuard = "if (!await guardCustomer()) throw new Error('redirecting');";
const newSetup = `/* الزائر المجهول يرى العروض والزر. الفتح يتطلب حساباً. */\r\nawait adoptIdentity().catch(() => null);`;
s = replaceOnce(s, oldGuard, newSetup, 'hard guard');

// Import adoptIdentity
s = replaceOnce(
  s,
  "import { sb, actorId, areaId, setArea, getGift, setGift, sar } from './assets/js/core.js';",
  "import { sb, actorId, areaId, setArea, getGift, setGift, sar, adoptIdentity } from './assets/js/core.js';",
  'core import'
);

// 3) Add public offers to stageClosed()
// Find the stageClosed function and add the offers container before the final closing div
const stageClosedStart = s.indexOf('function stageClosed() {');
if (stageClosedStart === -1) throw new Error('stageClosed not found');
const returnStart = s.indexOf('return `', stageClosedStart);
const closingDiv = s.indexOf('</div>\r\n\r\n    <div class="card mt">');
if (closingDiv === -1) throw new Error('closing div anchor not found');

const offersHtml = `</div>\r\n\r\n    <div class="card" id="gcOffersCard" hidden>\r\n` +
  `      <p class="small muted" style="margin:0 0 12px\">עברו לבחור עיר:</p>\r\n` +
  `      <div class="gc-offers" id="gcOffers"></div>\r\n`;

s = s.slice(0, closingDiv) + offersHtml + s.slice(closingDiv);

// 4) Add guardCustomer() to the open() function before the RPC call
const openFunc = 'async function open() {';
const openIdx = s.indexOf(openFunc);
if (openIdx === -1) throw new Error('open() function not found');
const rpcCall = "const { data, error } = await sb.rpc('open_daily_gift'";
const rpcIdx = s.indexOf(rpcCall, openIdx);
if (rpcIdx === -1) throw new Error('open_daily_gift RPC not found');

// Insert guardCustomer() and its redirect before the RPC
const guardCheck = `  const session = await guardCustomer();\r\n  if (!session) return; /* guardCustomer redirects */\r\n  `;
s = s.slice(0, rpcIdx) + guardCheck + s.slice(rpcIdx);

// 5) Add loadPublicOffers call at the end, after render()
const awaitRender = 'await render();';
const renderIdx = s.indexOf(awaitRender);
if (renderIdx === -1) throw new Error('await render() not found');
const afterRender = renderIdx + awaitRender.length;

const offersCall = `\r\n/* Load guest-visible offers (no auth required) */\r\n` +
  `await loadPublicOffers('gcOffers').then(count => {\r\n` +
  `  if (count > 0) $('#gcOffersCard').hidden = false;\r\n` +
  `});`;

s = s.slice(0, afterRender) + offersCall + s.slice(afterRender);

fs.writeFileSync(p, s, 'utf8');
console.log('gift.html:', before, '->', s.length, 'bytes');
console.log('loadPublicOffers import:', /from '\.\/assets\/js\/public-offers\.js'/.test(s));
console.log('adoptIdentity import:', /adoptIdentity[\s\S]*?from '\.\/assets\/js\/core\.js'/.test(s));
console.log('hard guard removed:', !s.includes("if (!await guardCustomer()) throw new Error('redirecting');"));
console.log('adoptIdentity().catch in setup:', /await adoptIdentity\(\)\.catch/.test(s));
console.log('guardCustomer in open():', s.includes('const session = await guardCustomer();'));
console.log('loadPublicOffers call added:', /await loadPublicOffers\('gcOffers'\)/.test(s));
