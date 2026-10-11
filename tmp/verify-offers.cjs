const fs = require('fs');
const s = fs.readFileSync('index.html', 'utf8');

const checks = {
  'gcOffers container present': s.includes('id="gcOffers"'),
  'gcTitle present': s.includes('id="gcTitle"'),
  'gcSub present': s.includes('id="gcSub"'),
  'shared module imported': s.includes("'./assets/js/public-offers.js'"),
  'shared call with gcOffers': /loadPublicOffers\('gcOffers'/.test(s),
  'inline loadPublicOffers removed': !/async function loadPublicOffers/.test(s),
  'inline .gc-offer css removed': !s.includes('.gc-offer{'),
  'old undefined esc() gone from module': (s.match(/\besc\(/g) || []).length === 0
};
for (const [k, v] of Object.entries(checks)) console.log((v ? 'OK   ' : 'FAIL ') + k);

console.log('\n--- module block tail (call site) ---');
const tag = '<script type="module">';
const st = s.indexOf(tag) + tag.length;
const en = s.indexOf('</script>', st);
const mod = s.slice(st, en);
console.log(mod.split(/\r?\n/).slice(-14).join('\n'));

console.log('\n--- CRLF integrity ---');
let crlf = 0, bare = 0;
for (let i = 0; i < s.length; i++) if (s[i] === '\n') { if (s[i - 1] === '\r') crlf++; else bare++; }
console.log('index.html CRLF:', crlf, 'bare LF:', bare);

const g = fs.readFileSync('gift.html', 'utf8');
let c2 = 0, b2 = 0;
for (let i = 0; i < g.length; i++) if (g[i] === '\n') { if (g[i - 1] === '\r') c2++; else b2++; }
console.log('gift.html  CRLF:', c2, 'bare LF:', b2);
