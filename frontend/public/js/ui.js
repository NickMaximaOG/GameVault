// Tiny DOM helpers. Text is always inserted as text nodes, never as HTML, so data from the API cannot inject markup.
export function h(tag, props = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props ?? {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k === 'style') Object.assign(el.style, v);          // CSSOM: allowed by the strict CSP
    else if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === 'value' || k === 'checked' || k === 'disabled' || k === 'selected') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) {
    if (kid === null || kid === undefined || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

export const $ = (sel, root = document) => root.querySelector(sel);

export function toast(message, bad = false) {
  const t = h('div', { class: 'toast' + (bad ? ' bad' : ''), text: message });
  $('#toasts').append(t);
  setTimeout(() => t.remove(), bad ? 6000 : 3500);
}

const dlg = () => $('#dlg');
/** Opens the shared dialog. Returns a close function. */
export function openDialog(title, body, { wide = false, onClose } = {}) {
  const d = dlg();
  d.className = wide ? 'wide' : '';
  d.replaceChildren(
    h('div', { class: 'dlg-head' }, h('h2', { text: title }),
      h('button', { class: 'btn ghost small', type: 'button', 'aria-label': 'Close', text: 'Close', onClick: () => d.close() })),
    h('div', { class: 'dlg-body' }, body),
  );
  d.onclose = () => { d.replaceChildren(); onClose?.(); };
  d.showModal();
  return () => d.close();
}

export function confirmDialog(title, message, actionLabel, danger = true) {
  return new Promise((resolve) => {
    let answered = false;
    const done = (v) => { answered = true; resolve(v); close(); };
    const close = openDialog(title, h('div', { class: 'stack' },
      h('p', { text: message }),
      h('div', { class: 'row' },
        h('button', { class: 'btn' + (danger ? ' danger' : ''), type: 'button', text: actionLabel, onClick: () => done(true) }),
        h('button', { class: 'btn ghost', type: 'button', text: 'Cancel', onClick: () => done(false) }))),
      { onClose: () => { if (!answered) resolve(false); } });
  });
}

// ---- formatting ------------------------------------------------------------------------------
export const fmtHours = (n) => (n === null || n === undefined ? '-' : `${Number(n).toLocaleString(undefined, { maximumFractionDigits: 1 })} h`);
export const fmtDate = (s) => (s ? new Date(s.length === 10 ? s + 'T00:00:00' : s).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : '-');
export const fmtDateTime = (s) => (s ? new Date(s).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '-');
export const money = (n) => Number(n ?? 0).toLocaleString(undefined, { style: 'currency', currency: 'USD' });
export const statusClass = (name) => 's-' + String(name).toLowerCase().replace(/\s+/g, '-');

function hue(title) {
  let x = 0;
  for (const c of title) x = (x * 31 + c.charCodeAt(0)) % 360;
  return x;
}
const initials = (t) => t.replace(/^(the|a|an)\s+/i, '').split(/[\s:]+/).filter(Boolean).slice(0, 2).map((w) => w[0]).join('').toUpperCase();

/** A generated "case front" for a game; shows the real cover when it loads. */
export function cover(game, kind = 'tall', ageLabel = null) {
  const hh = hue(game.title);
  const el = h('div', { class: `cover ${kind}`, style: { background: `linear-gradient(155deg, hsl(${hh} 55% 38%), hsl(${(hh + 40) % 360} 60% 22%))` }, 'aria-hidden': 'true' },
    initials(game.title));
  if (game.cover_image) {
    const img = h('img', { src: game.cover_image, alt: '', loading: 'lazy', referrerpolicy: 'no-referrer' });
    img.addEventListener('error', () => img.remove());
    el.prepend(img);
  }
  if (ageLabel) el.append(h('span', { class: 'age', text: ageLabel }));
  return el;
}
