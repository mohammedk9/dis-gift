/* توليد أيقونات PWA بصيغة PNG (بدون أي مكتبة خارجية)
   node tools/make-icons.cjs
*/
const fs = require('fs');
const zlib = require('zlib');

const OUT = 'assets';
fs.mkdirSync(OUT, { recursive: true });

/* ---------- helpers ---------- */
function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = c ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png(w, h, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;      // bit depth
  ihdr[9] = 6;      // RGBA
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;   // filter none
    rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))
  ]);
}

/* ---------- drawing ---------- */
const mix = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));

function draw(size) {
  const buf = Buffer.alloc(size * size * 4);
  const R = size * 0.22;                     // radius
  const top = [245, 150, 83], bot = [226, 85, 31];

  const set = (x, y, r, g, b, a) => {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    const i = (y * size + x) * 4;
    const na = a / 255, ia = 1 - na;
    buf[i]     = Math.round(r * na + buf[i] * ia);
    buf[i + 1] = Math.round(g * na + buf[i + 1] * ia);
    buf[i + 2] = Math.round(b * na + buf[i + 2] * ia);
    buf[i + 3] = Math.max(buf[i + 3], a);
  };

  // rounded-rect background with vertical gradient
  for (let y = 0; y < size; y++) {
    const c = mix(top, bot, y / size);
    for (let x = 0; x < size; x++) {
      const dx = Math.max(R - x, 0, x - (size - 1 - R));
      const dy = Math.max(R - y, 0, y - (size - 1 - R));
      if (dx * dx + dy * dy <= R * R) set(x, y, c[0], c[1], c[2], 255);
    }
  }

  // white gift-box glyph
  const s = size / 512;                 // scale from the 512 design grid
  const fill = (x0, y0, x1, y1, col) => {
    for (let y = Math.round(y0 * s); y < Math.round(y1 * s); y++)
      for (let x = Math.round(x0 * s); x < Math.round(x1 * s); x++)
        set(x, y, col[0], col[1], col[2], 255);
  };
  const punch = (x0, y0, x1, y1) => {   // erase back to transparent
    for (let y = Math.round(y0 * s); y < Math.round(y1 * s); y++)
      for (let x = Math.round(x0 * s); x < Math.round(x1 * s); x++) {
        if (x < 0 || y < 0 || x >= size || y >= size) continue;
        const i = (y * size + x) * 4;
        buf[i] = buf[i + 1] = buf[i + 2] = buf[i + 3] = 0;
      }
  };
  const WHITE = [255, 255, 255];

  // 1) ribbon vertical strip, full height of the gift (behind the box)
  fill(243, 96, 269, 404, WHITE);

  // 2) box body outline
  fill(136, 268, 376, 404, WHITE);
  punch(148, 280, 364, 392);            // hollow the body
  // restore the ribbon inside the body
  fill(243, 280, 269, 392, WHITE);

  // 3) lid outline
  fill(132, 216, 380, 268, WHITE);
  punch(144, 228, 368, 256);
  fill(243, 228, 269, 256, WHITE);

  // 4) bow loops — stroke arcs
  const arc = (cx, cy, rx, ry, a0, a1) => {
    for (let a = a0; a <= a1; a += 0.01) {
      const px = (cx + rx * Math.cos(a)) * s, py = (cy + ry * Math.sin(a)) * s;
      const t = 11 * s;
      for (let dy = -t; dy <= t; dy++)
        for (let dx = -t; dx <= t; dx++)
          if (dx * dx + dy * dy <= t * t)
            set(Math.round(px + dx), Math.round(py + dy), 255, 255, 255, 255);
    }
  };
  arc(206, 150, 62, 54, Math.PI * 1.12, Math.PI * 1.88);
  arc(306, 150, 62, 54, Math.PI * 1.12, Math.PI * 1.88);

  return png(size, size, buf);
}

const targets = [
  ['icon-192.png', 192], ['icon-512.png', 512], ['icon-180.png', 180]
];
for (const [name, size] of targets) {
  const file = OUT + '/' + name;
  fs.writeFileSync(file, draw(size));
  console.log('wrote ' + file + '  (' + fs.statSync(file).size + ' bytes)');
}
console.log('>>> icons generated');