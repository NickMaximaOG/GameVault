import { api } from '../api.js';
import { h, openDialog, confirmDialog, toast, fmtDate } from '../ui.js';

/** Rate or edit a review. `existing` may be null. Calls onDone() after a save or delete. */
export function rateDialog(gameId, title, existing, onDone) {
  const range = h('input', { id: 'r-val', type: 'range', min: 1, max: 10, value: existing?.rating ?? 7 });
  const out = h('b', { text: String(range.value) });
  range.addEventListener('input', () => { out.textContent = range.value; });
  const review = h('textarea', { id: 'r-text', maxlength: 5000, value: existing?.review_text ?? '' });
  const err = h('p', { class: 'err', role: 'alert' });
  let close;
  const form = h('form', { class: 'stack', onSubmit: async (e) => {
    e.preventDefault();
    err.textContent = '';
    try {
      await api('PUT', `/me/ratings/${gameId}`, { rating: Number(range.value), review: review.value.trim() || null, expectedVersion: existing?.row_version ?? null });
      toast('Rating saved');
      close(); onDone?.();
    } catch (x) {
      err.textContent = x.status === 409 ? 'This rating changed elsewhere. Close this window and reopen it to see the latest version.' : x.message;
    }
  } },
    h('div', null, h('label', { for: 'r-val' }, 'Score: ', out, ' / 10'), range),
    h('div', null, h('label', { for: 'r-text', text: 'Review (optional)' }), review),
    err,
    h('div', { class: 'row' }, h('button', { class: 'btn', type: 'submit', text: 'Save rating' }),
      existing && h('button', { class: 'btn danger', type: 'button', text: 'Delete rating', onClick: async () => {
        close();
        if (!(await confirmDialog('Delete rating', `Delete your rating for ${title}?`, 'Delete rating'))) return;
        try { await api('DELETE', `/me/ratings/${gameId}`); toast('Rating deleted'); onDone?.(); } catch (x) { toast(x.message, true); }
      } })));
  close = openDialog(`Rate ${title}`, form);
}

export async function ratingsPage({ refresh }) {
  const rows = await api('GET', '/me/ratings');
  return h('div', null,
    h('div', { class: 'page-head' }, h('div', null, h('h1', { text: 'My ratings' }), h('p', { class: 'muted', text: 'Scores and reviews you have written.' }))),
    rows.length
      ? h('div', { class: 'table-wrap' }, h('table', null,
          h('thead', null, h('tr', null, ['Game', 'Score', 'Review', 'Date', ''].map((t) => h('th', { text: t })))),
          h('tbody', null, rows.map((r) => h('tr', null,
            h('td', { text: r.title }), h('td', { class: 'score', text: `${r.rating}/10` }),
            h('td', { text: r.review_text ?? '' }), h('td', { text: fmtDate(r.review_date) }),
            h('td', null, h('button', { class: 'btn ghost small', type: 'button', text: 'Edit', onClick: () => rateDialog(r.game_id, r.title, r, refresh) })))))))
      : h('div', { class: 'empty' }, h('p', { text: 'You have not rated any games yet. Rate a game from your shelf.' }), h('a', { class: 'btn', href: '#/collection', text: 'Go to my shelf' })));
}
