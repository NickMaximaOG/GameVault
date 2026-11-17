import { api, qs, session } from '../api.js';
import { h, cover, openDialog, toast, fmtDate, fmtHours } from '../ui.js';

let lookups = null;
const state = { q: '', genres: [], match: 'all', platformId: '', ageRatingId: '', sort: 'title', dir: 'asc', page: 1 };

export async function catalogPage() {
  lookups ??= await api('GET', '/catalog/lookups');
  const results = h('div', { 'aria-live': 'polite' });
  const reload = () => load(results);

  const search = h('input', { id: 'c-q', type: 'search', value: state.q, placeholder: 'Title or description', maxlength: 100 });
  let t;
  search.addEventListener('input', () => { clearTimeout(t); t = setTimeout(() => { state.q = search.value; state.page = 1; reload(); }, 250); });

  const select = (id, label, items, key, val, txt) => {
    const s = h('select', { id, onChange: () => { state[key] = s.value; state.page = 1; reload(); } },
      h('option', { value: '', text: 'Any' }),
      items.map((i) => h('option', { value: i[val], text: txt(i), selected: String(state[key]) === String(i[val]) })));
    return h('div', null, h('label', { for: id, text: label }), s);
  };

  const chips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Genres' });
  const paintChips = () => chips.replaceChildren(...lookups.genres.map((g) => {
    const on = state.genres.includes(g.genre_id);
    return h('button', { class: 'chip', type: 'button', 'aria-pressed': String(on), text: g.name, onClick: () => {
      state.genres = on ? state.genres.filter((x) => x !== g.genre_id) : [...state.genres, g.genre_id];
      state.page = 1; paintChips(); reload();
    } });
  }));
  paintChips();

  const matchSeg = h('div', { class: 'seg', role: 'group', 'aria-label': 'Genre matching' });
  const paintMatch = () => matchSeg.replaceChildren(...[['all', 'All selected'], ['any', 'Any selected']].map(([v, t]) =>
    h('button', { type: 'button', 'aria-pressed': String(state.match === v), text: t, onClick: () => { state.match = v; paintMatch(); state.page = 1; reload(); } })));
  paintMatch();

  const sortSel = h('select', { id: 'c-sort', onChange: () => { [state.sort, state.dir] = sortSel.value.split(':'); state.page = 1; reload(); } },
    [['title:asc', 'Title A-Z'], ['rating:desc', 'Highest rated'], ['release:desc', 'Newest'], ['popularity:desc', 'Most rated']]
      .map(([v, t]) => h('option', { value: v, text: t, selected: v === `${state.sort}:${state.dir}` })));

  const filters = h('form', { class: 'filters', role: 'search', onSubmit: (e) => e.preventDefault() },
    h('div', null, h('label', { for: 'c-q', text: 'Search' }), search),
    h('div', null, h('label', { text: 'Genres' }), chips, h('div', { style: { marginTop: '8px' } }, matchSeg)),
    select('c-plat', 'Platform', lookups.platforms, 'platformId', 'platform_id', (p) => p.name),
    select('c-age', 'Age rating', lookups.ageRatings, 'ageRatingId', 'age_rating_id', (a) => `${a.rating_authority} ${a.label}`),
    h('div', null, h('label', { for: 'c-sort', text: 'Sort by' }), sortSel),
    h('button', { class: 'btn ghost small', type: 'button', text: 'Clear filters', onClick: () => {
      Object.assign(state, { q: '', genres: [], match: 'all', platformId: '', ageRatingId: '', sort: 'title', dir: 'asc', page: 1 });
      location.reload();
    } }));

  reload();
  return h('div', null,
    h('div', { class: 'page-head' }, h('div', null, h('h1', { text: 'Catalog' }), h('p', { class: 'muted', text: 'Browse every game and see what the community thinks.' }))),
    h('div', { class: 'catalog' }, filters, results));
}

async function load(box) {
  try {
    const d = await api('GET', '/catalog/games' + qs({
      q: state.q, genres: state.genres.join(','), match: state.match, platformId: state.platformId,
      ageRatingId: state.ageRatingId, sort: state.sort, dir: state.dir, page: state.page, size: 12 }));
    if (!d.items.length) {
      box.replaceChildren(h('div', { class: 'empty' }, h('p', { text: 'No games match these filters. Remove a genre or clear the search.' })));
      return;
    }
    const pages = Math.max(1, Math.ceil(d.total / d.size));
    box.replaceChildren(
      h('p', { class: 'muted small', text: `${d.total} game${d.total === 1 ? '' : 's'}` }),
      h('div', { class: 'grid' }, d.items.map(card)),
      h('div', { class: 'pager' },
        h('button', { class: 'btn ghost small', type: 'button', disabled: state.page <= 1, text: 'Previous', onClick: () => { state.page--; load(box); } }),
        h('span', { class: 'muted small', text: `Page ${state.page} of ${pages}` }),
        h('button', { class: 'btn ghost small', type: 'button', disabled: state.page >= pages, text: 'Next', onClick: () => { state.page++; load(box); } })));
  } catch (e) {
    box.replaceChildren(h('div', { class: 'empty' }, h('p', { text: e.message })));
  }
}

function card(g) {
  const first = g.age_ratings ? g.age_ratings.split(', ')[0] : null;
  return h('button', { class: 'case', type: 'button', onClick: () => showGame(g.game_id) },
    cover(g, 'tall', first),
    h('div', { class: 'info' },
      h('span', { class: 'title', text: g.title }),
      h('span', { class: 'muted small', text: g.genres ?? '' }),
      h('span', { class: 'small' }, h('span', { class: 'score', text: g.avg_rating ? `${Number(g.avg_rating).toFixed(1)} / 10` : 'Not rated' }),
        h('span', { class: 'muted', text: g.rating_count ? ` (${g.rating_count})` : '' }))));
}

async function showGame(id) {
  let g;
  try { g = await api('GET', `/catalog/games/${id}`); } catch (e) { toast(e.message, true); return; }
  const body = h('div', { class: 'stack' },
    h('div', { class: 'row' }, cover(g, 'mini'),
      h('div', null,
        h('div', { text: `${g.developer ?? 'Unknown developer'} / ${g.publisher ?? 'Unknown publisher'}` }),
        h('div', { class: 'muted small', text: `Released ${fmtDate(g.release_date)}` }))),
    g.description && h('p', { text: g.description }),
    h('div', { class: 'chips' }, g.genreList.map((x) => h('span', { class: 'tag', text: x.name })),
      g.ageRatingList.map((a) => h('span', { class: 'tag', text: `${a.rating_authority} ${a.label}` })),
      g.modes && h('span', { class: 'tag', text: g.modes })),
    h('div', null, h('b', { text: 'Platforms: ' }), g.platformList.map((p) => p.name).join(', ')),
    session.user ? addForm(g) : h('p', { class: 'muted' }, h('a', { href: '#/signin', text: 'Sign in' }), ' to add this game to your shelf.'),
    h('h3', { text: `Achievements (${g.achievements.length})` }),
    g.achievements.length
      ? h('div', null, g.achievements.map((a) => h('div', { class: 'ach' },
          h('div', null, h('b', { text: a.name }), a.description && h('div', { class: 'muted small', text: a.description })),
          h('div', { class: 'small', text: `${a.points} pts` }))))
      : h('p', { class: 'muted', text: 'No achievements are defined for this game.' }),
    h('h3', { text: `Reviews (${g.reviews.length})` }),
    g.reviews.length
      ? g.reviews.map((r) => h('div', { class: 'panel' }, h('b', { text: `${r.username}: ${r.rating}/10` }), r.review_text && h('p', { text: r.review_text })))
      : h('p', { class: 'muted', text: 'Nobody has reviewed this game yet.' }));
  openDialog(g.title, body, { wide: true });
}

function addForm(g) {
  const plat = h('select', { id: 'a-plat' }, g.platformList.map((p) => h('option', { value: p.platform_id, text: p.name })));
  const price = h('input', { id: 'a-price', type: 'number', min: 0, step: '0.01', placeholder: '0.00' });
  const err = h('p', { class: 'err', role: 'alert' });
  return h('form', { class: 'panel', onSubmit: async (e) => {
    e.preventDefault();
    err.textContent = '';
    try {
      await api('POST', '/me/collection', { gameId: g.game_id, platformId: Number(plat.value), price: price.value === '' ? null : Number(price.value) });
      toast(`${g.title} added to your shelf`);
      document.getElementById('dlg').close();
    } catch (x) { err.textContent = x.message; }
  } },
    h('h3', { text: 'Add to my shelf' }),
    h('div', { class: 'row' },
      h('div', null, h('label', { for: 'a-plat', text: 'Platform' }), plat),
      h('div', null, h('label', { for: 'a-price', text: 'Price paid' }), price),
      h('button', { class: 'btn', type: 'submit', text: 'Add to shelf', style: { alignSelf: 'flex-end' } })),
    err);
}
