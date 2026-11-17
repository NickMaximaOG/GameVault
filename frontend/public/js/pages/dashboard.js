import { api } from '../api.js';
import { h, fmtHours, fmtDate, money, statusClass } from '../ui.js';

export async function dashboardPage() {
  const d = await api('GET', '/me/dashboard');
  const s = d.summary ?? {};
  const tile = (label, value) => h('div', { class: 'tile' }, h('b', { text: value }), h('span', { class: 'muted small', text: label }));
  const maxHours = Math.max(1, ...d.byStatus.map((x) => Number(x.hours ?? 0)));
  return h('div', null,
    h('div', { class: 'page-head' }, h('h1', { text: 'Dashboard' })),
    h('div', { class: 'tiles' },
      tile('Games owned', s.games_owned ?? 0), tile('Hours played', fmtHours(s.total_playtime_hours)),
      tile('Completed', s.completed_games ?? 0), tile('Completion', s.completion_pct != null ? `${s.completion_pct}%` : '-'),
      tile('Achievement points', s.achievement_points ?? 0), tile('Spent', money(s.total_spent))),
    h('div', { class: 'cols' },
      h('section', { class: 'panel' }, h('h2', { text: 'Hours by status' }),
        d.byStatus.length ? d.byStatus.map((x) => h('div', { class: 'hbar' },
          h('span', { text: x.status }),
          h('div', { class: 'bar', role: 'img', 'aria-label': `${x.status}: ${fmtHours(x.hours)}` }, h('i', { class: statusClass(x.status), style: { width: (Number(x.hours) / maxHours * 100) + '%' } })),
          h('span', { class: 'small', text: `${x.games} / ${fmtHours(x.hours)}` })))
          : h('p', { class: 'muted', text: 'Add games to see hours by status.' })),
      h('section', { class: 'panel' }, h('h2', { text: 'Most played' }),
        d.topGames.length ? h('ol', null, d.topGames.map((g) => h('li', { text: `${g.title} on ${g.platform}: ${fmtHours(g.playtime_hours)}` }))) : h('p', { class: 'muted', text: 'Nothing played yet.' })),
      h('section', { class: 'panel' }, h('h2', { text: 'Recent unlocks' }),
        d.recentUnlocks.length ? h('ul', null, d.recentUnlocks.map((u) => h('li', { text: `${u.name} in ${u.game} (+${u.points}), ${fmtDate(u.unlocked_at)}` }))) : h('p', { class: 'muted', text: 'No achievements unlocked yet.' }))));
}
