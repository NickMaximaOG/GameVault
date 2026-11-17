import { api, qs } from '../api.js';
import { h, openDialog, confirmDialog, toast, fmtDate, fmtDateTime, fmtHours } from '../ui.js';

export async function adminPage({ refresh }) {
  const users = await api('GET', '/admin/users');
  const audit = h('div');
  const table = h('input', { id: 'au-t', placeholder: 'e.g. User_Game' });
  const loadAudit = async () => {
    try {
      const rows = await api('GET', '/admin/audit' + qs({ table: table.value.trim(), limit: 50 }));
      audit.replaceChildren(rows.length ? h('div', { class: 'table-wrap' }, h('table', null,
        h('thead', null, h('tr', null, ['When', 'Table', 'Record', 'Action', 'By', 'Change'].map((t) => h('th', { text: t })))),
        h('tbody', null, rows.map((r) => h('tr', null,
          h('td', { text: fmtDateTime(r.changed_at) }), h('td', { text: r.table_name }), h('td', { text: r.record_pk }),
          h('td', null, h('span', { class: `tag ${r.action}`, text: r.action })), h('td', { text: r.changed_by ?? 'system' }),
          h('td', { class: 'diff' }, diff(r)))))))
        : h('p', { class: 'muted', text: 'No audit entries match.' }));
    } catch (e) { audit.replaceChildren(h('p', { class: 'err', text: e.message })); }
  };
  loadAudit();
  return h('div', null,
    h('div', { class: 'page-head' }, h('h1', { text: 'Admin' })),
    h('h2', { text: 'Users' }),
    h('div', { class: 'table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['User', 'Email', 'Role', 'Games', 'Hours', 'Last sign-in', ''].map((t) => h('th', { text: t })))),
      h('tbody', null, users.map((u) => h('tr', null,
        h('td', { text: u.username }), h('td', { text: u.email }), h('td', { text: u.role }),
        h('td', { text: u.games_owned }), h('td', { text: fmtHours(u.total_playtime_hours) }), h('td', { text: fmtDate(u.last_login_at) }),
        h('td', null, h('div', { class: 'actions' },
          h('button', { class: 'btn ghost small', type: 'button', text: 'Deactivate', onClick: async () => {
            if (!(await confirmDialog('Deactivate user', `Deactivate ${u.username}? They can no longer sign in. Their data is kept.`, 'Deactivate'))) return;
            try { await api('POST', `/admin/users/${u.user_id}/deactivate`); toast('User deactivated'); refresh(); } catch (e) { toast(e.message, true); }
          } }),
          h('button', { class: 'btn danger small', type: 'button', text: 'Erase', onClick: () => eraseDialog(u, refresh) })))))))),
    h('h2', { style: { marginTop: '32px' }, text: 'Audit log' }),
    h('form', { class: 'row', onSubmit: (e) => { e.preventDefault(); loadAudit(); } },
      h('div', null, h('label', { for: 'au-t', text: 'Table' }), table), h('button', { class: 'btn ghost', type: 'submit', text: 'Filter', style: { alignSelf: 'flex-end' } })),
    audit);
}

function diff(r) {
  const o = r.old_values ?? {}, n = r.new_values ?? {};
  if (r.action === 'UPDATE') {
    const keys = Object.keys(n).filter((k) => JSON.stringify(n[k]) !== JSON.stringify(o[k]) && k !== 'updated_at' && k !== 'row_version');
    return keys.length ? keys.map((k) => h('div', null, h('code', { text: k }), ` ${JSON.stringify(o[k])} -> ${JSON.stringify(n[k])}`)) : '(housekeeping only)';
  }
  return JSON.stringify(r.action === 'DELETE' ? o : n).slice(0, 140);
}

function eraseDialog(u, refresh) {
  const confirmInput = h('input', { id: 'er-c', autocomplete: 'off' });
  const err = h('p', { class: 'err', role: 'alert' });
  let close;
  close = openDialog(`Erase ${u.username}`, h('form', { class: 'stack', onSubmit: async (e) => {
    e.preventDefault(); err.textContent = '';
    try { await api('POST', `/admin/users/${u.user_id}/erase`, { confirmUsername: confirmInput.value }); toast('User erased'); close(); refresh(); }
    catch (x) { err.textContent = x.message; }
  } },
    h('p', { text: 'This permanently deletes the account and all of its data, and removes personal details from the audit log. It cannot be undone.' }),
    h('div', null, h('label', { for: 'er-c', text: `Type ${u.username} to confirm` }), confirmInput),
    err, h('button', { class: 'btn danger', type: 'submit', text: 'Erase permanently' })));
}
