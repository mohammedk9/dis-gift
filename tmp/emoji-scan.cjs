/* read-only: يسرد كل موضع فيه رمز إيموجي داخل ملفات المشروع */
const fs = require('fs'), path = require('path');
const ROOT = process.cwd();
const SKIP = /node_modules|[\\/]\.git[\\/]|assets[\\/]js[\\/]vendor|[\\/]tmp[\\/]/;
const EXT = new Set(['.html', '.js', '.cjs', '.sql', '.md', '.json', '.webmanifest', '.css']);
/* إيموجي تصويري + رموز تزيينية + محدد التنويع */
const EMOJI = /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{2B50}\u{203C}\u{2049}\u{23F0}-\u{23FF}\u{24C2}\u{25AA}-\u{25FE}]/gu;
const out = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (SKIP.test(p)) continue;
    if (e.isDirectory()) walk(p);
    else if (EXT.has(path.extname(e.name))) {
      const lines = fs.readFileSync(p, 'utf8').split(/\r?\n/);
      lines.forEach((l, i) => {
        EMOJI.lastIndex = 0;
        if (EMOJI.test(l)) out.push(p.replace(ROOT + path.sep, '') + ':' + (i + 1) + ': ' + l.trim());
      });
    }
  }
})(ROOT);
fs.writeFileSync('tmp/emoji-report.txt', out.join('\n'));
console.log('EMOJI LINES: ' + out.length);
