#!/usr/bin/env node
/* Part 2: text-content emoji (toast, labels, data) — drop emoji, keep text */
const fs = require('fs');
const path = require('path');

const R = [];
const add = (file, from, to) => R.push({ file, from, to });

/* --- Toast calls: drop emoji --- */
add('account.html', "toast(data.status === 'granted' ? '✅ تم تسجيل موافقتك'", "toast(data.status === 'granted' ? 'تم تسجيل موافقتك'");
add('admin/settings.html', "toast('✅ تم حفظ الإعدادات')", "toast('تم حفظ الإعدادات')");
add('admin/settings.html', "toast('✅ تم تغيير كلمة المرور')", "toast('تم تغيير كلمة المرور')");
add('admin/statements.html', "toast('✅ تم إغلاق الفترة')", "toast('تم إغلاق الفترة')");
add('checkout.html', "toast('✅ أُنشئ الطلب — تأكيد السعر مطلوب')", "toast('أُنشئ الطلب — تأكيد السعر مطلوب')");
add('checkout.html', "toast('✅ تم إرسال الطلب للمنشأة')", "toast('تم إرسال الطلب للمنشأة')");
add('checkout.html', "toast('✅ تم تأكيد السعر — الطلب الآن عند المنشأة')", "toast('تم تأكيد السعر — الطلب الآن عند المنشأة')");
add('register.html', "toast('✅ تم إنشاء الحساب')", "toast('تم إنشاء الحساب')");
add('register.html', "toast('✅ تم التسجيل — بانتظار تفعيل الإدارة')", "toast('تم التسجيل — بانتظار تفعيل الإدارة')");
add('r/profile.html', "toast('✅ تم الحفظ')", "toast('تم الحفظ')");

/* --- Data labels: drop emoji --- */
add('admin/index.html', "['🎁 هدية مفتوحة'", "['هدية مفتوحة'");
add('admin/index.html', "['👁️ مشاهدة منيو'", "['مشاهدة منيو'");
add('admin/index.html', "['🛒 سلة'", "['سلة'");
add('admin/index.html', "['📋 طلب'", "['طلب'");
add('admin/index.html', "['✅ طلب مكتمل'", "['طلب مكتمل'");
add('admin/offers.html', "free_item:    (o) => `🎁 ${o.gift_label", "free_item:    (o) => `${o.gift_label");
add('admin/offers.html', "restaurant: '🍽️ مطعم'", "restaurant: 'مطعم'");
add('admin/offers.html', "cafe: '☕ كافيه'", "cafe: 'كافيه'");
add('admin/offers.html', "salon: '💇 صالون'", "salon: 'صالون'");
add('admin/offers.html', "store: '🏪 متجر'", "store: 'متجر'");
add('admin/offers.html', "services: '🛠️ خدمات'", "services: 'خدمات'");
add('admin/offers.html', "other: '📦 أخرى'", "other: 'أخرى'");
add('admin/restaurants.html', "'💬 0${esc(r.whatsapp", "'0${esc(r.whatsapp");
add('checkout.html', "<h3 class=\"section-title\" style=\"margin-top:0;font-size:15px\">1️⃣ طريقة الاستلام</h3>", '<h3 class="section-title" style="margin-top:0;font-size:15px">طريقة الاستلام</h3>');
add('checkout.html', "<h3 class=\"section-title\" style=\"margin-top:0;font-size:15px\">2️⃣ بيانات التواصل</h3>", '<h3 class="section-title" style="margin-top:0;font-size:15px">بيانات التواصل</h3>');
add('checkout.html', "<h3 class=\"section-title\" style=\"margin-top:0;font-size:15px\">3️⃣ الموافقات</h3>", '<h3 class="section-title" style="margin-top:0;font-size:15px">الموافقات</h3>');
add('checkout.html', "<h3 class=\"modal-title\">✅ تم إنشاء طلبك</h3>", '<h3 class="modal-title">تم إنشاء طلبك</h3>');
add('checkout.html', '<div class="alert alert-info">💵 الدفع يتم مباشرة مع المنشأة', '<div class="alert alert-info">الدفع يتم مباشرة مع المنشأة');
add('checkout.html', '🎁 ${esc(gift.gift.gift_label', '${esc(gift.gift.gift_label');
add('checkout.html', '⭐ عند اكتمال هذا الطلب', 'عند اكتمال هذا الطلب');
add('r/offers.html', "free_item: `<span class=\"badge badge-green\">🎁 ${esc(o.gift_label", "free_item: `<span class=\"badge badge-green\">${esc(o.gift_label");
add('r/offers.html', "<option value=\"free_item\"    ${oo.kind === 'free_item' ? 'selected' : ''}>🎁 صنف مجاني", "<option value=\"free_item\"    ${oo.kind === 'free_item' ? 'selected' : ''}>صنف مجاني");
add('r/orders.html', "ready:    [['completed','✅ تم التسليم'],", "ready:    [['completed','تم التسليم'],");
add('r/orders.html', "${o.address ? `<p class=\"small muted mt\">📍 ${esc(o.address)", "${o.address ? `<p class=\"small muted mt\">${esc(o.address)");
add('r/orders.html', "${o.note ? `<p class=\"small muted\">📝 ${esc(o.note)", "${o.note ? `<p class=\"small muted\">${esc(o.note)");
add('r/orders.html', "💬 إرسال الفاتورة", "إرسال الفاتورة");
add('r/orders.html', "⭐ منح ${rsettings", "منح ${rsettings");
add('r/orders.html', "? `✅ تم — رسوم المنصة", "? `تم — رسوم المنصة");
add('r/orders.html', "? `⭐ أُضيفت ${data.points}", "? `أُضيفت ${data.points}");
add('r/orders.html', ": `⭐ ${data.points} نقطة", ": `${data.points} نقطة");
add('r/profile.html', "[['restaurant','🍽️ مطعم']", "[['restaurant','مطعم']");
add('r/profile.html', "['cafe','☕ كافيه']", "['cafe','كافيه']");
add('r/profile.html', "['salon','💇 صالون']", "['salon','صالون']");
add('r/profile.html', "['store','🏪 متجر']", "['store','متجر']");
add('r/profile.html', "['services','🛠️ خدمات']", "['services','خدمات']");
add('r/profile.html', "['other','📦 أخرى']", "['other','أخرى']");
add('r/scan.html', "ready:    [['completed','✅ تم التسليم'],", "ready:    [['completed','تم التسليم'],");
add('r/scan.html', "<button class=\"btn btn-primary btn-block\" id=\"grant\">⭐ منح النقاط</button>", '<button class="btn btn-primary btn-block" id="grant">منح النقاط</button>');
add('r/scan.html', "${o.address ? `<p class=\"small muted mt\">📍 ${esc(o.address)", "${o.address ? `<p class=\"small muted mt\">${esc(o.address)");
add('r/scan.html', "${o.note ? `<p class=\"small muted\">📝 ${esc(o.note)", "${o.note ? `<p class=\"small muted\">${esc(o.note)");
add('r/scan.html', "? `⭐ أُضيفت ${data.points}", "? `أُضيفت ${data.points}");
add('r/scan.html', ": `⭐ ${data.points} نقطة", ": `${data.points} نقطة");
add('r/scan.html', "? `✅ تم التسليم — ${data.points", "? `تم التسليم — ${data.points");
add('README.md', '> ⚠️ **لا تفتح الملفات بـ `file://`**', '> **لا تفتح الملفات بـ `file://`**');
add('README.md', '> 💡 `check:sql`', '> `check:sql`');
add('README.md', '| `/gift.html` | 🎁 هدية اليوم', '| `/gift.html` | هدية اليوم');
add('manifest.webmanifest', '"🎁 هدية اليوم"', '"هدية اليوم"');
add('manifest.webmanifest', '"📋 طلباتي"', '"طلباتي"');

module.exports = { R, add };
