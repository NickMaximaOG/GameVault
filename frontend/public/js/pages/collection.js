import { api } from '../api.js';
import { h, cover, openDialog, confirmDialog, toast, fmtHours, fmtDate, money, statusClass } from '../ui.js';
import { rateDialog } from './ratings.js';

const STATUSES = [[1, 'Backlog'], [2, 'Playing'], [3, 'Completed'], [4, 'On Hold'], [5, 'Dropped']];
let filter = 0;

export async function collectionPage({ refresh }) {
  const items = await api('GET', '/me/collection');
  const shown = filter ? items.filter((i) => i.status_id === filter) : items;
  const list = h('div');

  const entryEls = new Map();
  for (const it of shown) {
    const el = entryRow(it, refresh);
    entryEls.set(it.user_game_id, el);
    list.append(el);
  }

  const maxH = Math.max(1, ...items.map((i) => Number(i.playtime_hours)));
  const spines = items.map((it) => {
    const height = 70 + Math.round((Number(it.playtime_hours) / maxH) * 110);   // taller spine = more hours played
    return h('button', { class: `spine ${statusClass(it.status)}`, type: 'button', style: { height: height + 'px' },
      title: `${it.title}: ${fmtHours(it.playtime_hours)}, ${it.status}`, 'aria-label': `${it.title}, ${it.status}, ${fmtHours(it.playtime_hours)}`,
      text: it.title, onClick: () => {
        if (filter && filter !== it.status_id) { filter = 0; refresh().then(() => flash(it.user_game_id)); return; }
        flash(it.user_game_id);
      } });
  });
  function flash(id) {
    const el = document.querySelector(`[data-entry="${id}"]`);
    if (!el) return;
    el.scrollIntoView({ block: 'center', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
    el.classList.add('flash'); el.focus(); setTimeout(() => el.classList.remove('flash'), 1400);
  }

  if (!items.length) {
    return h('div', null, h('div', { class: 'page-head' }, h('h1', { text: 'My shelf' })),
      h('div', { class: 'empty' }, h('p', { text: 'Your shelf is empty. Find a game in the catalog and add it.' }), h('a', { class: 'btn', href: '#/catalog', text: 'Browse the catalog' })));
  }

  return h('div', null,
    h('div', { class: 'page-head' }, h('div', null, h('h1', { text: 'My shelf' }),
      h('p', { class: 'muted', text: `${items.length} games. Taller spines have more hours played.` }))),
    h('div', { class: 'shelf', role: 'group', 'aria-label': 'Shelf of games' }, spines), h('div', { class: 'shelf-board' }),
    h('div', { class: 'legend' }, STATUSES.map(([, n]) => h('span', null, h('i', { class: statusClass(n) }), n))),
    h('div', { class: 'tabs', role: 'group', 'aria-label': 'Filter by status' },
      [[0, 'All'], ...STATUSES].map(([id, n]) => h('button', { class: 'chip', type: 'button', 'aria-pressed': String(filter === id), text: n,
        onClick: () => { filter = id; refresh(); } }))),
    shown.length ? list : h('div', { class: 'empty' }, h('p', { text: 'No games with this status.' })));
}

function entryRow(it, refresh) {
  const sel = h('select', { 'aria-label': `Status of ${it.title}`, onChange: async () => {
    try {
      await api('PATCH', `/me/collection/${it.user_game_id}`, { statusId: Number(sel.value), expectedVersion: it.row_version });
      toast('Status updated'); refresh();
    } catch (e) {
      toast(e.status === 409 ? 'This entry changed elsewhere. Reloaded the latest.' : e.message, true);
      refresh();
    }
  } }, STATUSES.map(([id, n]) => h('option', { value: id, text: n, selected: id === it.status_id })));
  const pct = it.achievements_total ? Math.round((it.achievements_unlocked / it.achievements_total) * 100) : 0;
  return h('div', { class: 'entry', 'data-entry': it.user_game_id, tabindex: '-1' },
    cover(it, 'mini'),
    h('div', null, h('b', { text: it.title }), h('div', { class: 'muted small', text: `${it.platform}${it.purchase_price != null ? ' / ' + money(it.purchase_price) : ''}` })),
    sel,
    h('div', { class: 'score', text: fmtHours(it.playtime_hours) }),
    h('div', { class: 'grow' }, h('div', { class: 'small muted', text: it.achievements_total ? `${it.achievements_unlocked}/${it.achievements_total} achievements` : 'No achievements' }),
      it.achievements_total > 0 && h('div', { class: 'bar', role: 'img', 'aria-label': `${pct}% of achievements unlocked` }, h('i', { style: { width: pct + '%' } }))),
    h('div', { class: 'actions' },
      h('button', { class: 'btn ghost small', type: 'button', text: 'Log time', onClick: () => logDialog(it, refresh) }),
      h('button', { class: 'btn ghost small', type: 'button', text: 'Achievements', disabled: !it.achievements_total, onClick: () => achDialog(it, refresh) }),
      h('button', { class: 'btn ghost small', type: 'button', text: it.my_rating ? `Rated ${it.my_rating}/10` : 'Rate', onClick: () => rateDialog(it.game_id, it.title, null, refresh) }),
      h('button', { class: 'btn danger small', type: 'button', text: 'Remove', onClick: async () => {
        if (!(await confirmDialog('Remove game', `Remove ${it.title} from your shelf? Your play history for it is kept but hidden.`, 'Remove'))) return;
        try { await api('DELETE', `/me/collection/${it.user_game_id}`); toast('Removed'); refresh(); } catch (e) { toast(e.message, true); }
      } })));
}

function logDialog(it, refresh) {
  const now = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 16);
  const when = h('input', { id: 'l-when', type: 'datetime-local', value: now, max: now, required: true });
  const mins = h('input', { id: 'l-min', type: 'number', min: 1, max: 1440, value: 60, required: true });
  const note = h('input', { id: 'l-note', maxlength: 255 });
  const err = h('p', { class: 'err', role: 'alert' });
  let close;
  close = openDialog(`Log time for ${it.title}`, h('form', { class: 'stack', onSubmit: async (e) => {
    e.preventDefault(); err.textContent = '';
    try {
      // the browser knows the local zone; send an absolute instant so the server stores UTC
      await api('POST', `/me/collection/${it.user_game_id}/sessions`, { startedAt: new Date(when.value).toISOString(), minutes: Number(mins.value), note: note.value.trim() || null });
      toast('Play session logged'); close(); refresh();
    } catch (x) { err.textContent = x.message; }
  } },
    h('div', null, h('label', { for: 'l-when', text: 'Started' }), when),
    h('div', null, h('label', { for: 'l-min', text: 'Minutes played' }), mins),
    h('div', null, h('label', { for: 'l-note', text: 'Note (optional)' }), note),
    err, h('button', { class: 'btn', type: 'submit', text: 'Log session' })));
}

async function achDialog(it, refresh) {
  const body = h('div');
  let dirty = false;
  const paint = async () => {
    const list = await api('GET', `/me/collection/${it.user_game_id}/achievements`);
    body.replaceChildren(...list.map((a) => {
      const inp = h('input', { type: 'number', min: 0, max: 100, step: '1', value: Number(a.progress), 'aria-label': `Progress for ${a.name}` });
      return h('div', { class: 'ach' },
        h('div', null, h('b', { text: a.name }), a.description && h('div', { class: 'muted small', text: a.description }),
          a.is_unlocked ? h('div', { class: 'small', text: `Unlocked ${fmtDate(a.unlocked_at)} (+${a.points} pts)` }) : h('div', { class: 'small muted', text: `${a.points} pts` })),
        h('div', { class: 'ctl' }, inp, h('span', { class: 'small', text: '%' }),
          h('button', { class: 'btn ghost small', type: 'button', text: 'Save', onClick: async () => {
            try { await api('PUT', `/me/collection/${it.user_game_id}/achievements/${a.achievement_id}`, { progress: Number(inp.value) }); dirty = true; toast('Progress saved'); await paint(); }
            catch (x) { toast(x.message, true); }
          } })),
        h('div', { class: 'bar' }, h('i', { style: { width: Number(a.progress) + '%' } })));
    }));
  };
  await paint();
  openDialog(`${it.title}: achievements`, body, { wide: true, onClose: () => { if (dirty) refresh(); } });
}
