import { api, session, ApiError } from './api.js';
import { h, $, toast } from './ui.js';
import { authPage } from './pages/auth.js';
import { catalogPage } from './pages/catalog.js';
import { collectionPage } from './pages/collection.js';
import { dashboardPage } from './pages/dashboard.js';
import { ratingsPage } from './pages/ratings.js';
import { adminPage } from './pages/admin.js';

const routes = {
  catalog:    { title: 'Catalog',    render: catalogPage },
  collection: { title: 'My shelf',   render: collectionPage, auth: true },
  dashboard:  { title: 'Dashboard',  render: dashboardPage, auth: true },
  ratings:    { title: 'My ratings', render: ratingsPage, auth: true },
  admin:      { title: 'Admin',      render: adminPage, auth: true, admin: true },
  signin:     { title: 'Sign in',    render: authPage },
};

const logo = () => {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 64 64');
  svg.setAttribute('aria-hidden', 'true');
  for (const [x, y, w, hh, c] of [[12, 14, 10, 36, '#7f9dff'], [26, 8, 10, 42, '#2fb596'], [40, 20, 10, 30, '#e0a21b'], [8, 50, 48, 4, '#edeff3']]) {
    const r = document.createElementNS(ns, 'rect');
    for (const [k, v] of Object.entries({ x, y, width: w, height: hh, rx: 2, fill: c })) r.setAttribute(k, v);
    svg.append(r);
  }
  return svg;
};

function currentRoute() {
  const [name, ...rest] = (location.hash.replace(/^#\/?/, '') || 'catalog').split('/');
  return { name: routes[name] ? name : 'catalog', args: rest };
}

function renderTop(active) {
  const links = [['catalog', 'Catalog']];
  if (session.user) links.push(['collection', 'My shelf'], ['dashboard', 'Dashboard'], ['ratings', 'My ratings']);
  if (session.user?.role === 'ADMIN') links.push(['admin', 'Admin']);
  const who = session.user
    ? h('div', { class: 'who' }, h('span', { text: session.user.username }),
        h('button', { class: 'btn ghost small', type: 'button', text: 'Sign out', onClick: signOut }))
    : h('div', { class: 'who' }, h('a', { class: 'btn ghost small', href: '#/signin', text: 'Sign in' }));
  $('#top').replaceChildren(h('div', { class: 'topbar' },
    h('a', { class: 'brand', href: '#/catalog' }, logo(), 'GameVault'),
    h('nav', { 'aria-label': 'Main' }, links.map(([n, t]) => h('a', { href: '#/' + n, text: t, 'aria-current': n === active ? 'page' : null }))),
    who));
}

let renderId = 0;
export async function render() {
  const id = ++renderId;
  const { name, args } = currentRoute();
  const r = routes[name];
  if ((r.auth && !session.user) || (r.admin && session.user?.role !== 'ADMIN')) {
    location.replace(session.user ? '#/catalog' : '#/signin');
    return;
  }
  renderTop(name);
  document.title = `${r.title} - GameVault`;
  const app = $('#app');
  app.replaceChildren(h('p', { class: 'muted', text: 'Loading...' }));
  try {
    const view = await r.render({ args, refresh: render, signedIn: afterSignIn });
    if (id !== renderId) return;                       // a newer navigation won
    app.replaceChildren(view);
    app.focus({ preventScroll: true });
  } catch (e) {
    if (id !== renderId) return;
    app.replaceChildren(h('div', { class: 'empty' }, h('p', { text: e.message }),
      h('button', { class: 'btn', type: 'button', text: 'Try again', onClick: render })));
  }
}

async function afterSignIn() {
  session.user = await api('GET', '/auth/me');
  location.hash = '#/collection';
  render();
}

async function signOut() {
  try { await api('POST', '/auth/logout'); } catch { /* already signed out */ }
  session.user = null;
  location.hash = '#/catalog';
  render();
}

session.onExpired = () => {
  session.user = null;
  toast('Your session expired. Sign in again.', true);
  location.hash = '#/signin';
  render();
};

window.addEventListener('hashchange', render);
try { session.user = await api('GET', '/auth/me'); } catch (e) { if (!(e instanceof ApiError)) toast(e.message, true); }
render();
