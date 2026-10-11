/* ============================================================
   public-offers.js — shared offer loading for guest visibility
   ============================================================
   Guests see the offer list (no value, no code) on index.html
   and gift.html. The claim action (open_daily_gift) and ordering
   (checkout.html) remain authenticated. */

import { sb, areaId } from './core.js';

function esc(s) {
  return String(s).replace(/[&<>"]/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}

const ICON_DEFS = {
  percent: '<circle cx="12" cy="12" r="9"/><path d="M8 8l8 8M16 8l-8 8"/>',
  fixed_amount: '<rect x="3" y="8" width="18" height="4" rx="1"/><path d="M12 8v13"/>',
  free_item: '<rect x="3" y="8" width="18" height="4" rx="1"/><path d="M19 12v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-7"/><path d="M7.5 8a2.5 2.5 0 0 1 0-5C11 3 12 8 12 8s1-5 4.5-5a2.5 2.5 0 0 1 0 5"/>'
};

function icon(name) {
  const inner = ICON_DEFS[name] || ICON_DEFS.free_item;
  return `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`;
}

/** Load and render public offers (guest-visible, no auth required).
    Shows up to 3 offers. Calls titleEl/subtitleEl setters if provided.
    Returns the count of offers rendered. */
export async function loadPublicOffers(containerId, { maxOffers = 3, titleEl = null, subtitleEl = null } = {}) {
  const container = document.getElementById(containerId);
  if (!container) return 0;

  try {
    const { data } = await sb.rpc('public_offers', { p_area: areaId() || null });
    if (!Array.isArray(data) || !data.length) return 0;

    const offers = data.slice(0, maxOffers);
    container.innerHTML = offers.map(o => `
      <div class="gc-offer">
        <div class="gc-offer-ico">${icon(o.offer.kind)}</div>
        <div class="gc-offer-txt">
          <div class="gc-offer-name">${esc(o.restaurant)}</div>
          <div class="gc-offer-kind">${esc(o.offer.title.slice(0, 24))}</div>
        </div>
      </div>`).join('');

    container.hidden = false;
    if (titleEl) titleEl.textContent = 'عروضك اليومية';
    if (subtitleEl) subtitleEl.textContent = offers.length + ' عرض متاح';
    
    return offers.length;
  } catch {
    return 0;
  }
}
