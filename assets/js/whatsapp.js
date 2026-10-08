/* ============================================================
   whatsapp.js — واتساب كقناة توصيل لفاتورة الطلب
   القاعدة: نص الفاتورة يأتي من السيرفر دائماً
   (customer_order_share / staff_order_share).
   هذا الملف يبني رابط wa.me فقط — ولا يحسب أي مبلغ أو كود.
   ============================================================ */

export const WA_HOST = 'https://wa.me/';

/* تطبيع محلي للمعاينة والتحقق السريع فقط.
   المرجع النهائي هو public.normalize_whatsapp على السيرفر. */
export function localNormalizeWhatsapp(value) {
  const digits = String(value ?? '').replace(/[^0-9]/g, '');
  if (!digits) return null;
  let local = digits;
  if (local.startsWith('00966')) local = local.slice(3);
  if (local.startsWith('966')) local = local.slice(4);
  if (local.startsWith('0')) local = local.slice(1);
  return /^5\d{8}$/.test(local) ? '966' + local : null;
}

/* عرض مقروء: 051 234 5678 */
export function whatsappDisplay(value) {
  const full = localNormalizeWhatsapp(value);
  if (!full) return '';
  return '0' + full.slice(3).replace(/(\d{2})(\d{3})(\d{4})/, '$1 $2 $3');
}

export function waLink(phone, text) {
  const full = localNormalizeWhatsapp(phone);
  if (!full) return null;
  return WA_HOST + full + '?text=' + encodeURIComponent(String(text ?? ''));
}

/* يفتح واتساب في تبويب جديد. false = لا يوجد رقم صالح. */
export function openWhatsApp(phone, text) {
  const url = waLink(phone, text);
  if (!url) return false;
  const win = window.open(url, '_blank', 'noopener');
  if (!win) location.href = url;        // مانع النوافذ المنبثقة
  return true;
}
