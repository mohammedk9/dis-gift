/* ============================================================
   barcode.js — مولّد Code 39 محلي (SVG) بلا أي مكتبة خارجية
   ------------------------------------------------------------
   لماذا Code 39؟
   - الكود المستخدم هو code الطلب نفسه: 6 خانات hex (0-9A-F)،
     وكلها داخل مجموعة Code 39 بلا تعديل ⇒ لا نحتاج توليد كود ثانٍ.
   - لا يحتاج مكتبة ولا اتصالاً بالشبكة: المشروع كله ملفات ثابتة
     بلا CDN، فالمولّد مكتوب هنا بالكامل.
   - الرسم SVG متجهي: يبقى حاداً عند التكبير ويُطبع بلا تشويه.
   ============================================================ */

/* جدول Code 39 القياسي: 9 عناصر لكل رمز (شريط، فراغ، شريط … )
   و'1' تعني عنصراً عريضاً. عدد العناصر العريضة دائماً 3. */
export const CODE39_TABLE = {
  '0': '000110100', '1': '100100001', '2': '001100001', '3': '101100000',
  '4': '000110001', '5': '100110000', '6': '001110000', '7': '000100101',
  '8': '100100100', '9': '001100100',
  'A': '100001001', 'B': '001001001', 'C': '101001000', 'D': '000011001',
  'E': '100011000', 'F': '001011000', 'G': '000001101', 'H': '100001100',
  'I': '001001100', 'J': '000011100', 'K': '100000011', 'L': '001000011',
  'M': '101000010', 'N': '000010011', 'O': '100010010', 'P': '001010010',
  'Q': '000000111', 'R': '100000110', 'S': '001000110', 'T': '000010110',
  'U': '110000001', 'V': '011000001', 'W': '111000000', 'X': '010010001',
  'Y': '110010000', 'Z': '011010000',
  '-': '010000101', '.': '110000100', ' ': '011000100',
  '$': '010101000', '/': '010100010', '+': '010001010', '%': '000101010',
  '*': '010010100'   // رمز البداية/النهاية (لا يُشفَّر كنص)
};

/* حدود العرض: من 2:1 إلى 3:1 هو النطاق الذي تقبله ماسحات Code 39 */
const NARROW = 2;          // وحدة ضيقة
const WIDE = NARROW * 3;   // وحدة عريضة
const GAP = NARROW;        // فاصل بين الرموز
const QUIET = NARROW * 10; // المنطقة الهادئة على كل جانب

/** هل يمكن ترميز هذا النص بـ Code 39؟ */
export function isCode39(text) {
  const value = String(text ?? '').toUpperCase();
  return !!value && /^[0-9A-Z\-. $/+%]+$/.test(value);
}

/** ارتفاعات الأشرطة (px) محسوبة من النص — تُستخدم في المعاينة فقط */
export function code39Modules(text) {
  const value = String(text ?? '').toUpperCase();
  if (!isCode39(value)) return 0;
  // كل رمز = 9 عناصر + فاصل، ثم رمزا البداية والنهاية
  let modules = 0;
  for (const ch of '*' + value + '*') {
    for (const bit of CODE39_TABLE[ch]) modules += bit === '1' ? 3 : 1;
    modules += 1;
  }
  return modules + QUIET * 2 / NARROW;   // بالوحدات الضيقة
}

/**
 * يرجع باركود Code 39 كـ SVG (نص HTML) — أو '' إذا كان النص غير قابل للترميز.
 * opts: { height, narrow, label } — label = الكود المكتوب تحت الأشرطة
 */
export function code39Svg(text, opts = {}) {
  const value = String(text ?? '').toUpperCase();
  if (!isCode39(value)) return '';

  const narrow = Number(opts.narrow) > 0 ? Number(opts.narrow) : NARROW;
  const wide = narrow * 3;
  const gap = narrow;
  const quiet = narrow * 10;
  const barHeight = Number(opts.height) > 0 ? Number(opts.height) : 72;
  const label = opts.label === undefined ? value : String(opts.label);
  const labelHeight = label ? 20 : 0;
  const totalHeight = barHeight + labelHeight;

  let x = quiet;
  let bars = '';
  for (const ch of '*' + value + '*') {
    const pattern = CODE39_TABLE[ch];
    for (let i = 0; i < 9; i++) {
      const w = pattern[i] === '1' ? wide : narrow;
      if (i % 2 === 0) {
        bars += `<rect x="${x}" y="0" width="${w}" height="${barHeight}"/>`;
      }
      x += w;
    }
    x += gap;
  }
  const totalWidth = x + quiet;

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${totalWidth} ${totalHeight}"`
    + ` width="${totalWidth}" height="${totalHeight}" role="img"`
    + ` aria-label="باركود الطلب ${value}" preserveAspectRatio="xMidYMid meet"`
    + ` style="width:100%;height:auto;max-width:100%">`
    + `<rect x="0" y="0" width="${totalWidth}" height="${totalHeight}" fill="#ffffff"/>`
    + `<g fill="#000000">${bars}</g>`
    + (label
      ? `<text x="${totalWidth / 2}" y="${barHeight + 15}" text-anchor="middle"`
        + ` font-family="ui-monospace,Menlo,Consolas,monospace" font-size="14"`
        + ` letter-spacing="3">${label}</text>`
      : '')
    + `</svg>`;
}

/** نفس الباركود كـ data URI — للطباعة أو الإرسال كصورة */
export function code39DataUri(text, opts = {}) {
  const svg = code39Svg(text, opts);
  return svg ? 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg) : '';
}
