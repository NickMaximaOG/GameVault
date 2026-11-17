import { api } from '../api.js';
import { h, toast } from '../ui.js';

export function authPage({ signedIn }) {
  let mode = 'in';
  const err = h('p', { class: 'err', role: 'alert' });
  const username = h('input', { id: 'f-user', autocomplete: 'username', required: true, maxlength: 30 });
  const email = h('input', { id: 'f-mail', type: 'email', autocomplete: 'email', maxlength: 255 });
  const password = h('input', { id: 'f-pass', type: 'password', required: true, maxlength: 128 });
  const emailField = h('div', { class: 'field' }, h('label', { for: 'f-mail', text: 'Email' }), email);
  const title = h('h1');
  const submit = h('button', { class: 'btn', type: 'submit' });
  const swap = h('button', { class: 'btn ghost small', type: 'button' });
  const hint = h('p', { class: 'muted small' });

  function paint() {
    const reg = mode === 'up';
    title.textContent = reg ? 'Create your shelf' : 'Sign in';
    submit.textContent = reg ? 'Create account' : 'Sign in';
    swap.textContent = reg ? 'I already have an account' : 'Create an account';
    emailField.hidden = !reg;
    email.required = reg;
    username.labels?.[0] && (username.labels[0].textContent = reg ? 'Username' : 'Username or email');
    password.autocomplete = reg ? 'new-password' : 'current-password';
    hint.textContent = reg ? 'Use at least 10 characters, with letters and numbers.' : 'Demo account: aarav_k / ChangeMe!2026';
    err.textContent = '';
  }

  const form = h('form', { class: 'panel card-auth', novalidate: true, onSubmit: async (ev) => {
    ev.preventDefault();
    err.textContent = '';
    submit.disabled = true;
    try {
      if (mode === 'up') {
        await api('POST', '/auth/register', { username: username.value.trim(), email: email.value.trim(), password: password.value });
        toast('Account created');
      }
      await api('POST', '/auth/login', { username: username.value.trim(), password: password.value });
      await signedIn();
    } catch (e) {
      err.textContent = e.message;
    } finally {
      submit.disabled = false;
    }
  } },
    title,
    h('div', { class: 'field' }, h('label', { for: 'f-user', text: 'Username' }), username),
    emailField,
    h('div', { class: 'field' }, h('label', { for: 'f-pass', text: 'Password' }), password),
    err,
    h('div', { class: 'row' }, submit, swap),
    hint);
  swap.addEventListener('click', () => { mode = mode === 'in' ? 'up' : 'in'; paint(); });
  paint();
  return form;
}
