/* CRLF-safe edit of index.html:
   - import the shared public-offers module
   - drop the inline loadPublicOffers() (it referenced esc()/areaId() that
     were never imported in this module block, so it silently threw)
   - call the shared loader with the card's title/subtitle elements */
const fs = require('fs');
const p = 'index.html';
let s = fs.readFileSync(p, 'utf8');
const before = s.length;

function replaceOnce(haystack, from, to, label) {
  const i = haystack.indexOf(from);
  if (i === -1) throw new Error('anchor not found: ' + label);
  if (haystack.indexOf(from, i + 1) !== -1) throw new Error('anchor not unique: ' + label);
  return haystack.slice(0, i) + to + haystack.slice(i + from.length);
}

// 1) import the shared module alongside the existing core.js import
s = replaceOnce(
  s,
  "import { sb, isConfigured, adoptIdentity } from './assets/js/core.js';",
  "import { sb, isConfigured, adoptIdentity } from './assets/js/core.js';\r\n" +
  "import { loadPublicOffers } from './assets/js/public-offers.js';",
  'core import'
);

// 2) replace the inline function + its call with the shared call
const fnStart = s.indexOf('async function loadPublicOffers() {');
if (fnStart === -1) throw new Error('inline loadPublicOffers not found');
const callMarker = 'loadPublicOffers();';
const callIdx = s.indexOf(callMarker, fnStart);
if (callIdx === -1) throw new Error('inline loadPublicOffers() call not found');
const fnEnd = callIdx + callMarker.length;

const replacement = [
  "  /* العروض النشطة تُبنى في وحدة مشتركة مع صفحة الهدية (بلا قيمة ولا كود).\r",
  "     الفتح (open_daily_gift) وحده يتطلب حساباً. */\r",
  "  if (isConfigured()) {\r",
  "    loadPublicOffers('gcOffers', {\r",
  "      titleEl: document.getElementById('gcTitle'),\r",
  "      subtitleEl: document.getElementById('gcSub')\r",
  "    });\r",
  "  }"
].join('\n');

s = s.slice(0, fnStart) + replacement + s.slice(fnEnd);

fs.writeFileSync(p, s, 'utf8');
console.log('index.html:', before, '->', s.length, 'bytes');
console.log('inline loadPublicOffers remains:', /async function loadPublicOffers/.test(s));
console.log('import added:', /from '\.\/assets\/js\/public-offers\.js'/.test(s));
console.log('shared call added:', /loadPublicOffers\('gcOffers'/.test(s));
