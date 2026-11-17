const { chromium } = require('playwright');
const out = (process.env.SHOT_DIR || '/tmp') + '/';
(async () => {
  const b = await chromium.launch({ headless: true });
  const p = await (await b.newContext({ viewport: { width: 1440, height: 960 } })).newPage();
  const problems = [];
  p.on('console', m => { if (m.type() === 'error') problems.push('console: ' + m.text()); });
  p.on('pageerror', e => problems.push('pageerror: ' + e.message));
  const step = async (n, f) => { try { await f(); console.log('ok  ', n); } catch (e) { console.log('FAIL', n, '-', e.message.split('\n')[0]); } };
  await p.goto('http://localhost:3000/');
  await step('React sign-in screen renders', async () => { await p.waitForSelector('.auth-card'); if (!(await p.locator('h2').first().innerText()).includes('Sign in')) throw new Error('auth heading missing'); });
  await step('admin login opens dashboard first', async () => {
    await p.getByPlaceholder('Your username').fill('admin');
    await p.getByPlaceholder('Your password').fill('ChangeMe!2026');
    await p.getByRole('button', { name: 'Sign in' }).click();
    await p.waitForSelector('.hero-banner');
    if (!(await p.locator('.page-heading h1').innerText()).includes('Welcome back')) throw new Error('dashboard not first page');
  });
  await p.screenshot({ path: out + '1-dashboard.png', fullPage: true });
  await step('catalogue loads artwork and upcoming filter', async () => {
    await p.getByRole('button', { name: 'Discover' }).click();
    await p.waitForSelector('.game-card');
    await p.getByRole('button', { name: 'Upcoming' }).click();
  });
  await step('admin analytics and catalogue editor', async () => {
    await p.getByRole('button', { name: 'Admin studio' }).click();
    await p.waitForSelector('.admin-stats');
    await p.getByRole('button', { name: 'Add a game' }).click();
    await p.getByLabel('Game title').fill('E2E Demo Game');
    await p.getByLabel('Description').fill('A game created by the GameVault UI walkthrough.');
    await p.getByLabel('Upcoming release').check();
    await p.locator('.check-row').first().locator('input').first().check();
    await p.getByRole('button', { name: 'Create game' }).click();
    await p.waitForSelector('.toast.show');
  });
  await p.screenshot({ path: out + '2-admin.png', fullPage: true });
  await step('dark and light theme toggle', async () => {
    await p.locator('.top-actions button').nth(1).click();
    const theme = await p.locator('html').getAttribute('data-theme');
    if (!['dark', 'light'].includes(theme)) throw new Error('theme missing');
  });
  await step('HttpOnly login cookie', async () => {
    const c = (await p.context().cookies()).find(x => x.name === 'gv_session');
    if (!c?.httpOnly) throw new Error('cookie missing/not HttpOnly');
  });
  await step('logout', async () => { await p.locator('.user-chip .icon-btn').click(); await p.waitForSelector('.auth-card'); });
  await step('friend progress page', async () => {
    await p.getByPlaceholder('Your username').fill('NickMaxima');
    await p.getByPlaceholder('Your password').fill('ChangeMe!2026');
    await p.getByRole('button', { name: 'Sign in' }).click();
    await p.waitForSelector('.hero-banner');
    await p.getByRole('button', { name: 'Friends' }).click();
    await p.waitForSelector('.friend-progress');
  });
  await p.screenshot({ path: out + '3-friends.png', fullPage: true });
  await p.setViewportSize({ width: 390, height: 844 });
  await p.screenshot({ path: out + '4-mobile.png', fullPage: true });
  console.log('console problems:', problems.length ? problems : 'none');
  await b.close();
})();
