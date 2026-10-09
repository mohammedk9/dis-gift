/* ============================================================
   auth-flows.js — منطق تسجيل الحسابات (مستخدم / منشأة)
   يُستخدم من register.html (صفحة التسجيل المستقلة) ومن login.html
   (لإكمال تسجيل منشأة كانت بانتظار تأكيد البريد).
   ============================================================ */
import { sb, appUrl } from './core.js';

/* ---------- ?next= : مسار داخلي فقط ---------- */
export function safeNext(raw) {
  if (!raw) return '';
  const root = new URL(appUrl(''), location.origin).pathname;
  const path = raw.startsWith('/') && !raw.startsWith('//') ? raw : appUrl(raw);
  const url = new URL(path, location.origin);
  if (url.origin !== location.origin || !url.pathname.startsWith(root)) return '';
  return url.pathname + url.search + url.hash;
}

/* ---------- جهة الوصول المناسبة لدور الحساب ---------- */
export async function destinationFor(audience, next = '') {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return null;
  const { data: profile } = await sb.from('profiles')
    .select('role').eq('id', session.user.id).maybeSingle();
  const { data: admin } = await sb.from('admin_users')
    .select('user_id').eq('user_id', session.user.id).maybeSingle();
  const isAdmin = !!admin;
  const role = profile?.role;

  if (audience === 'customer' && role === 'customer') {
    return next && !/\/(r|admin)\//.test(next) ? next : appUrl('index.html');
  }
  if (audience === 'business' && isAdmin) {
    return next.includes('/admin/') ? next : appUrl('admin/');
  }
  if (audience === 'business' && role === 'restaurant') {
    return next && !next.includes('/admin/') ? next : appUrl('r/');
  }
  return null;
}

/* ---------- تسجيل منشأة (يُنفَّذ بعد وجود جلسة) ---------- */
export async function registerRestaurant(p) {
  const { data: res, error } = await sb.rpc('register_restaurant', {
    p_name: p.name,
    p_phone: p.phone,
    p_address: p.addr ?? p.address ?? null,
    p_area: p.area ? Number(p.area) : null,
    p_pickup: p.pickup,
    p_delivery: p.delivery,
    p_business: p.biz ?? p.business,
    p_whatsapp: p.whatsapp || null
  });
  if (error) return { error: error.message };
  if (!res?.ok) return { error: res?.error || 'تعذّر إنشاء المنشأة' };
  return { ok: true, data: res };
}

/* ---------- تسجيل منشأة بانتظار تأكيد البريد ----------
   بيانات المنشأة تُحفظ في user_metadata داخل الحساب نفسه، لا في المتصفح،
   فتصمد أمام تأكيد البريد من جهاز آخر أو من تطبيق البريد. */
const META_KEY = 'pending_restaurant';

export const pendingRestaurantOf = user => user?.user_metadata?.[META_KEY] || null;

export async function clearPendingRestaurant() {
  const { error } = await sb.auth.updateUser({ data: { [META_KEY]: null } });
  return !error;
}

/* يكمل التسجيل المعلّق من بيانات الحساب بعد تأكيد البريد وتسجيل الدخول. */
export async function finishPendingRegistration() {
  const { data: { session } } = await sb.auth.getSession();
  const pending = pendingRestaurantOf(session?.user);
  if (!pending) return { handled: false };

  const res = await registerRestaurant(pending);
  /* already_registered = المنشأة أُنشئت في محاولة سابقة (أو من جهاز آخر):
     نُكمل إلى اللوحة بدل رسالة خطأ تعيد المستخدم إلى نقطة الصفر. */
  if (res.error && res.error !== 'already_registered') {
    return { handled: true, message: res.error, code: res.error };
  }

  await clearPendingRestaurant();
  return {
    handled: true,
    message: 'تم التسجيل — بانتظار تفعيل الإدارة',
    redirect: appUrl('r/')
  };
}

/* ---------- تسجيل عميل ---------- */
export async function customerSignUp({ name, email, password, mode = 'customer' }) {
  const { data, error } = await sb.auth.signUp({
    email, password,
    options: {
      data: { full_name: name },
      emailRedirectTo: new URL(appUrl('login.html'), location.href).href
        + '?mode=' + mode
    }
  });
  if (error) return { error: error.message };
  return { ok: true, session: data.session };
}

/* ---------- تسجيل منشأة: حساب ثم منشأة ---------- */
export async function businessSignUp({ name, email, password, phone, payload }) {
  const { data, error } = await sb.auth.signUp({
    email, password,
    options: {
      // بيانات المنشأة تُحفظ مع الحساب نفسه، لا في localStorage:
      // بعد تأكيد البريد من أي جهاز تُقرَأ من user_metadata فتُنشأ المنشأة تلقائياً.
      data: { full_name: name, phone, [META_KEY]: { ...payload, email, name, phone } },
      emailRedirectTo: new URL(appUrl('login.html'), location.href).href
    }
  });
  if (error) return { error: error.message };

  // بريد بحاجة تأكيد ⇒ البيانات محفوظة في الحساب وتكتمل عند أول دخول.
  if (!data.session) return { ok: true, session: false };

  const res = await registerRestaurant({ ...payload, email, name, phone });
  if (res.error) return { error: res.error };
  await clearPendingRestaurant();
  return { ok: true, session: true, restaurantId: res.data.restaurant_id };
}
