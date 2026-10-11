/* Two CRLF-safe edits:
   A) index.html — drop the inline .gc-offer* block (now shared in app.css)
   B) gift.html  — guests see the offer list; the claim stays behind
      guardCustomer() so no value/code leaks and the invariant grep still
      finds guardCustomer() in the file. */
const fs = require('fs');

function once(haystack, from, to, label) {
  const i = haystack.indexOf(from);
  if (i === -1) throw new Error('anchor not found: ' + label);
  if (haystack.indexOf(from, i + 1) !== -1) throw new Error('anchor not unique: ' + label);
  return haystack.slice(0, i) + to + haystack.slice(i + from.length);
}
const crlf = lines => lines.join('\r\n');

/* ---------------- A) index.html ---------------- */
{
  const p = 'index.html';
  let s = fs.readFileSync(p, 'utf8');
  const before = s.length;

  const cssStart =
    '  /* قائمة العروض النشطة داخل بطاقة الهدية — للزائر والمستخدم معاً */\r\n' +
    '  .gc-offers{\r\n';
  const cssEnd = '  .gc-offers-note{position:relative;z-index:1;margin:8px 0 0;font-size:12px;color:rgba(255,255,255,.85)}\r\n';

  const i = s.indexOf(cssStart);
  if (i === -1) throw new Error('index: .gc-offers css block not found');
  const j = s.indexOf(cssEnd, i);
  if (j === -1) throw new Error('index: .gc-offers css block end not found');
  s = s.slice(0, i) + s.slice(j + cssEnd.length);

  fs.writeFileSync(p, s, 'utf8');
  console.log('index.html:', before, '->', s.length,
    '| inline .gc-offer css removed:', !s.includes('.gc-offer{'));
}

/* ---------------- B) gift.html ---------------- */
{
  const p = 'gift.html';
  let s = fs.readFileSync(p, 'utf8');
  const before = s.length;

  // 1) import adoptIdentity (guest identity) + the shared offers loader
  s = once(s,
    "import { sb, actorId, areaId, setArea, getGift, setGift, sar } from './assets/js/core.js';",
    "import { sb, actorId, areaId, setArea, getGift, setGift, sar, adoptIdentity } from './assets/js/core.js';",
    'core import');

  s = once(s,
    "import { $, esc, toast, modal, requireConfig, customerNav, initPWA, guardCustomer } from './assets/js/ui.js';",
    crlf([
      "import { $, esc, toast, modal, requireConfig, customerNav, initPWA, guardCustomer } from './assets/js/ui.js';",
      "import { loadPublicOffers } from './assets/js/public-offers.js';"
    ]),
    'ui import');

  // 2) page load: no hard redirect. Guests keep the identity; only the
  //    claim action (below) demands an account.
  s = once(s,
    crlf([
      "/* كود الهدية لا يظهر إلا لصاحب حساب — الزائر يُحوَّل إلى الدخول */",
      "if (!await guardCustomer()) throw new Error('redirecting');"
    ]),
    crlf([
      "/* الزائر المجهول يرى العروض والزر؛ قيمة الهدية وكودها يظهران لصاحب حساب فقط،",
      "   وطلب الفتح (open_daily_gift) يحتاج حساباً — يُفرض عند الضغط على الزر. */",
      "await adoptIdentity().catch(() => null);"
    ]),
    'page-load guard');

  // 3) offers list inside the orange card, under the "one gift per day" line
  s = once(s,
    crlf([
      '        <p style="margin:16px 0 0;font-size:11.5px;opacity:.85">هدية واحدة يومياً لكل جهاز</p>',
      '      </div>'
    ]),
    crlf([
      '        <p style="margin:16px 0 0;font-size:11.5px;opacity:.85">هدية واحدة يومياً لكل جهاز</p>',
      '        <!-- العروض النشطة يُراها الزائر أيضاً — بلا قيمة ولا كود. -->',
      '        <div class="gc-offers" id="gcOffers" hidden></div>',
      '      </div>'
    ]),
    'offers container');

  // 4) render guests' offers whenever the closed stage is shown
  s = once(s,
    crlf([
      '  stage.innerHTML = stageClosed();',
      "  $('#openBtn').onclick = open;",
      '}'
    ]),
    crlf([
      '  stage.innerHTML = stageClosed();',
      "  $('#openBtn').onclick = open;",
      '  /* العروض عامة: تظهر للزائر قبل الدخول، وتُخفي نفسها إن لا عروض. */',
      "  loadPublicOffers('gcOffers');",
      '}'
    ]),
    'render offers');

  // 5) the claim action is what requires an account
  s = once(s,
    crlf([
      '  btn.innerHTML = \'<span class="spin"></span> جارٍ الفتح…\';',
      "  const { data, error } = await sb.rpc('open_daily_gift', {"
    ]),
    crlf([
      '  btn.innerHTML = \'<span class="spin"></span> جارٍ الفتح…\';',
      '  /* لا كود ولا هدية لزائر: guardCustomer يُعيده إلى الدخول إن لم يكن مسجّلاً. */',
      '  const session = await guardCustomer();',
      '  if (!session) return;',
      "  const { data, error } = await sb.rpc('open_daily_gift', {"
    ]),
    'claim guard');

  fs.writeFileSync(p, s, 'utf8');
  console.log('gift.html :', before, '->', s.length,
    '| offers import:', /from '\.\/assets\/js\/public-offers\.js'/.test(s),
    '| guard at claim:', /const session = await guardCustomer\(\);/.test(s),
    '| guest identity:', /await adoptIdentity\(\)\.catch/.test(s),
    '| offers mount:', /loadPublicOffers\('gcOffers'\)/.test(s));
}
