/* استبدال دالة renderAccountState بنسخة سليمة (الملف CRLF فالمطابقة متعددة الأسطر تفشل) */
const fs = require('fs');
const FILE = 'index.html';
const raw = fs.readFileSync(FILE, 'utf8');
const lines = raw.split('\r\n');

const start = lines.findIndex(l => l.includes('async function renderAccountState(user)'));
const end = lines.findIndex((l, i) => i > start && l === '}');
if (start < 0 || end < 0) { console.error('FAIL anchors not found', start, end); process.exit(1); }

console.log('replacing lines', start + 1, '..', end + 1);
console.log('first:', JSON.stringify(lines[start]));
console.log('last :', JSON.stringify(lines[end]));

const block = [
  'async function renderAccountState(user) {',
  '  const guest = document.getElementById(\'accountGuest\');',
  '  const member = document.getElementById(\'accountMember\');',
  '  const nameEl = document.getElementById(\'accountMemberName\');',
  '  if (!guest || !member) return;',
  '  guest.hidden = !!user;',
  '  member.hidden = !user;',
  '  if (!user) return;',
  '',
  '  /* الاسم من ملف الحساب؛ وعند تعذّره نكتفي ببريده بدل اسم مُلفَّق. */',
  '  let name = String(user.user_metadata?.full_name || \'\').trim();',
  '',
  '  /* صاحب منشأة: نقرأ منشأته لنعرض رابط لوحته بدل روابط التسجيل.',
  '     بدون ذلك يظهر صاحب المنشأة كأنه غير مسجّل بعد الدخول. */',
  '  let restaurantId = null;',
  '  let restaurantName = \'\';',
  '  try {',
  '    const { data } = await sb.from(\'profiles\')',
  '      .select(\'full_name, role\').eq(\'id\', user.id).maybeSingle();',
  '    name = String(data?.full_name || name).trim();',
  '',
  '    if (data?.role === \'restaurant\') {',
  '      const { data: staff } = await sb.from(\'restaurant_staff\')',
  '        .select(\'restaurant_id\').eq(\'user_id\', user.id).limit(1).maybeSingle();',
  '      if (staff?.restaurant_id) {',
  '        restaurantId = staff.restaurant_id;',
  '        const { data: rest } = await sb.from(\'restaurants\')',
  '          .select(\'name\').eq(\'id\', staff.restaurant_id).maybeSingle();',
  '        restaurantName = String(rest?.name || \'\').trim();',
  '      }',
  '    }',
  '  } catch { /* الاسم والمنشأة اختيارية في القائمة */ }',
  '',
  '  if (nameEl) nameEl.textContent = name || (user.email ? user.email.split(\'@\')[0] : \'حسابي\');',
  '',
  '  /* رابط لوحة المنشأة يظهر لصاحب منشأة فقط. */',
  '  const bizLink = document.getElementById(\'accountBizLink\');',
  '  if (bizLink) {',
  '    bizLink.hidden = !restaurantId;',
  '    const bizName = document.getElementById(\'accountBizName\');',
  '    if (bizName) bizName.textContent = restaurantName || \'لوحة منشأتي\';',
  '  }',
  '}'
];

lines.splice(start, end - start + 1, ...block);
fs.writeFileSync(FILE, lines.join('\r\n'), 'utf8');
console.log('done');
