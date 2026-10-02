// Kiosk Fleet Web - the page. Everything it shows comes from the server
// (kfw, the Python app); everything it does goes back there, where the role
// is checked again. Nothing from the server is ever put into the page as
// HTML: text goes in as text.
'use strict';

const S = {
  me: null,
  fleet: null,
  live: null,
  stamp: '',
  view: 'Overview',
  selected: null,
  filter: '',
  onlyProblems: false,
  sort: { key: null, dir: 1 },
  screenChoice: {},
  products: [],
  deploy: {
    product: 'NG', rollback: false, ticks: new Set(), filter: '',
    extra: { NG: [], PBI: [], WEB: [], WATCHDOG: [] },
    opts: { restart: false, warnSeconds: 60, verifyMinutes: 12, force: false, updateConfig: false, keepLegacy: false, keepWatchdog: false, registerTask: false, kioskUser: '', dryRun: true },
    preview: '', error: ''
  },
  run: { from: 0, text: '', serial: null, timer: null },
  reports: [],
  audit: [],
  auditFilter: '',
  users: [],
  settings: null,
  pollTimer: null,
  toastTimer: null,
  modal: null
};

const NAMES = { NG: 'Mach2 Launcher NG', PBI: 'PBI Launcher', WEB: 'Web Launcher' };
const TAB_KIND = { Mach2: 'NG', PBI: 'PBI', Web: 'WEB' };
const TAB_TITLE = { Mach2: 'Mach2 kiosks', PBI: 'Power BI screens', Web: 'Web page screens', Other: 'Other kiosks' };

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
function el(tag, props, ...kids) {
  const e = document.createElement(tag);
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (v === undefined || v === null || v === false) continue;
      if (k === 'class') e.className = v;
      else if (k === 'text') e.textContent = v;
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else if (k === 'style') Object.assign(e.style, v);
      else if (k in e && typeof v !== 'string') e[k] = v;
      else e.setAttribute(k, v === true ? '' : v);
    }
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid === null || kid === undefined || kid === false) continue;
    e.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return e;
}
const $ = (sel, root) => (root || document).querySelector(sel);
// replaceChildren, but nested lists are spread and nothing (null, false)
// stays nothing instead of turning into the text "null".
function setKids(node, ...kids) {
  node.replaceChildren(...kids.flat(Infinity).filter((k) => k !== null && k !== undefined && k !== false));
}
const can = (what) => !!(S.me && S.me.allowed && S.me.allowed.includes(what));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const plural = (n, one, many) => (n === 1 ? one : many);

class ApiError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

async function api(method, path, body) {
  const opts = { method, credentials: 'same-origin', headers: {} };
  if (method !== 'GET') {
    if (S.me && S.me.csrf) opts.headers['X-Fleet-Csrf'] = S.me.csrf;
    if (body !== undefined) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
  }
  let res;
  try { res = await fetch(path, opts); }
  catch (e) { throw new ApiError(0, 'The server does not answer.'); }
  let data = null;
  const type = res.headers.get('Content-Type') || '';
  if (type.includes('application/json')) { try { data = await res.json(); } catch (e) { data = null; } }
  if (res.status === 401 && path !== '/api/me' && path !== '/api/login' && path !== '/api/setup' && path !== '/api/me/password') {
    signedOut('You have been signed out.');
    throw new ApiError(401, 'Signed out.');
  }
  if (!res.ok) throw new ApiError(res.status, (data && data.error) || ('HTTP ' + res.status));
  return data;
}

function toast(text, sev, seconds) {
  let t = $('#toast');
  if (!t) { t = el('div', { id: 'toast', role: 'status' }); document.body.append(t); }
  t.className = 'toast ' + (sev || '');
  t.textContent = text;
  t.classList.remove('hidden');
  clearTimeout(S.toastTimer);
  S.toastTimer = setTimeout(() => t.classList.add('hidden'), (seconds || 6) * 1000);
}

async function copyText(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied.', 'OK', 3); }
  catch (e) { toast('Could not copy - select it and copy by hand.', 'WARNING'); }
}

function pill(status, sev) { return el('span', { class: 'pill ' + (sev || 'UNKNOWN'), text: status || '' }); }

// ---------------------------------------------------------------------------
// Signing in and out
// ---------------------------------------------------------------------------
async function start() {
  let r, d = null;
  try {
    r = await fetch('/api/me', { credentials: 'same-origin' });
    d = await r.json().catch(() => null);
  } catch (e) { $('#app').textContent = 'The server does not answer.'; return; }
  const token = new URLSearchParams(location.search).get('token');
  if (r.status === 401 && d && d.setup && location.pathname === '/setup' && token) return renderSetup(token);
  // Signed out, /api/me answers 401 with how to sign in.
  if (r.status === 401) return renderLogin('', d);
  if (!r.ok || !d) { $('#app').textContent = (d && d.error) || ('HTTP ' + r.status); return; }
  S.me = d;
  enter();
}

// Into the app - or, for an account whose password was set by an admin,
// first a new password of its own.
function enter() {
  if (location.pathname === '/setup') history.replaceState(null, '', '/');
  if (S.me && S.me.mustChange) return renderForcedPassword();
  boot();
}

function loginFrame(title, sub, card) {
  const app = $('#app');
  app.className = '';
  setKids(app, el('div', { class: 'login' }, el('h1', { text: title }), el('div', { class: 'dim', text: sub }), card));
}

async function renderLogin(message, known) {
  stopPolling();
  closeModal();
  let info = known;
  if (!info) { try { info = await (await fetch('/api/me', { credentials: 'same-origin' })).json(); } catch (e) { info = {}; } }
  const note = el('div', { class: 'note sev-CRITICAL', role: 'alert', text: message || '' });
  const user = el('input', { type: 'text', autocomplete: 'username', required: true, maxLength: 64 });
  const pass = el('input', { type: 'password', autocomplete: 'current-password', required: true, maxLength: 256 });
  const go = el('button', { class: 'btn primary', type: 'submit', text: 'Sign in' });
  const form = el('form', null,
    el('label', null, el('span', { class: 'lbl', text: 'Account' }), user),
    el('label', null, el('span', { class: 'lbl', text: 'Password' }), pass),
    el('div', { style: { marginTop: '14px' } }, go));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    go.disabled = true;
    note.textContent = '';
    try {
      S.me = await api('POST', '/api/login', { user: user.value, password: pass.value });
      pass.value = '';
      enter();
    } catch (e) { note.textContent = e.message; go.disabled = false; pass.select(); }
  });
  const card = el('div', { class: 'card' }, form);
  if (info && info.setup) card.append(el('p', { class: 'hint', text: 'No accounts yet: open the setup link from the server\'s log to make the first admin.' }));
  if (info && info.insecure) card.append(el('p', { class: 'hint sev-WARNING', text: 'This connection is not encrypted: your password crosses the network as typed. Ask for the https:// address.' }));
  card.append(note);
  loginFrame('Kiosk Fleet', 'Every kiosk screen, and what can be done to it.', card);
  setTimeout(() => user.focus(), 0);
}

function passwordForm(o) {
  const note = el('div', { class: 'note sev-CRITICAL', role: 'alert' });
  const inputs = {};
  const field = (key, label, type, auto) => {
    inputs[key] = el('input', { type, autocomplete: auto, required: true, maxLength: key === 'user' ? 64 : 256 });
    return el('label', null, el('span', { class: 'lbl', text: label }), inputs[key]);
  };
  const go = el('button', { class: 'btn primary', type: 'submit', text: o.okText });
  const form = el('form', null, o.fields.map((f) => field(...f)),
    el('p', { class: 'hint', text: 'At least 12 characters, with three of: lower case, upper case, digits, symbols - or 20 characters or more.' }),
    el('div', { style: { marginTop: '14px' } }, go), note);
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    go.disabled = true;
    note.textContent = '';
    const v = {};
    for (const [k, i] of Object.entries(inputs)) v[k] = i.value;
    try { await o.onOk(v); }
    catch (e) { note.textContent = e.message; go.disabled = false; }
  });
  setTimeout(() => Object.values(inputs)[0].focus(), 0);
  return el('div', { class: 'card' }, form);
}

function renderSetup(token) {
  loginFrame('Kiosk Fleet - first start', 'Make the first admin account. More accounts are added in Users afterwards.', passwordForm({
    okText: 'Make the account',
    fields: [['user', 'Account name', 'text', 'username'], ['password', 'Password', 'password', 'new-password'], ['password2', 'Password again', 'password', 'new-password']],
    onOk: async (v) => {
      if (v.password !== v.password2) throw new Error('The two passwords did not match.');
      S.me = await api('POST', '/api/setup', { token, user: v.user, password: v.password, password2: v.password2 });
      enter();
    }
  }));
}

function renderForcedPassword() {
  stopPolling();
  loginFrame('New password', `${S.me.user}: your password was set by an admin. Choose your own before you carry on.`, passwordForm({
    okText: 'Change it',
    fields: [['current', 'Current password', 'password', 'current-password'], ['password', 'New password', 'password', 'new-password'], ['password2', 'New password again', 'password', 'new-password']],
    onOk: async (v) => {
      if (v.password !== v.password2) throw new Error('The two new passwords did not match.');
      await api('POST', '/api/me/password', v);
      S.me = await api('GET', '/api/me');
      enter();
    }
  }));
}

function signedOut(message) {
  S.me = null;
  renderLogin(message);
}

async function signOut() {
  try { await api('POST', '/api/logout'); } catch (e) { /* signed out either way */ }
  signedOut('Signed out.');
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------
function boot() {
  const app = $('#app');
  app.className = '';
  setKids(app, 
    el('div', { class: 'shell' },
      el('header', { class: 'top', id: 'top' }),
      el('div', { class: 'banners', id: 'banners' }),
      el('nav', { class: 'nav', id: 'nav', 'aria-label': 'Views' }),
      el('main', { class: 'main', id: 'main' })));
  S.fleet = null;
  S.stamp = '';
  loadProducts();
  poll();
}

function stopPolling() {
  clearTimeout(S.pollTimer);
  clearTimeout(S.run.timer);
  S.pollTimer = null;
}

async function poll() {
  clearTimeout(S.pollTimer);
  if (!S.me) return;
  try {
    const data = await api('GET', '/api/state?since=' + encodeURIComponent(S.stamp));
    const changed = !!data.fleet;
    if (data.fleet) S.fleet = data.fleet;
    S.live = data.live;
    S.stamp = data.live.stamp;
    renderTop();
    renderBanners();
    renderNav();
    renderView(changed);
  } catch (e) {
    if (e.status === 401) return;
    if (e.status === 428) { S.me.mustChange = true; return renderForcedPassword(); }
    toast(e.message, 'CRITICAL', 4);
  }
  S.pollTimer = setTimeout(poll, S.live && S.live.run ? 2000 : 5000);
}

function refreshSoon() {
  clearTimeout(S.pollTimer);
  S.pollTimer = setTimeout(poll, 300);
}

function renderTop() {
  const top = $('#top');
  if (!top) return;
  const f = S.fleet, L = S.live;
  let head;
  if (!f || !f.Ok) head = el('span', { class: 'headline warn' }, el('span', { class: 'dot' }), 'NO DATA');
  else if (f.Attention === 0) head = el('span', { class: 'headline ok' }, el('span', { class: 'dot' }), `ALL ${f.Total} KIOSKS OK`);
  else head = el('span', { class: 'headline crit' }, el('span', { class: 'dot' }), `${f.Attention} KIOSK${f.Attention === 1 ? ' NEEDS' : 'S NEED'} ATTENTION`);

  const fresh = el('span', { class: 'fresh' + (L.fresh.stale ? ' stale' : ''), text: f && !f.Ok ? f.Error : L.fresh.text });
  const kids = [el('span', { class: 'brand', text: 'KIOSK FLEET' }), head, fresh, el('span', { class: 'spacer' })];

  if (L.run && L.run.kind === 'scan') {
    const bar = el('span', { class: 'bar' }, el('i', { style: { width: (L.run.scan ? L.run.scan.pct : 0) + '%' } }));
    kids.push(el('span', { class: 'scanbar', title: 'started by ' + L.run.who }, 'scanning', bar, (L.run.scan ? L.run.scan.text : '') + '  ' + L.run.elapsed));
  }
  if (can('scan')) {
    kids.push(el('button', { class: 'btn small', type: 'button', text: 'Scan now', disabled: !!L.run, title: 'Run the collector once', onclick: scanNow }));
  }
  const auto = L.autoscan;
  if (can('autoscan')) {
    kids.push(el('button', {
      class: 'btn small' + (auto.on ? ' on' : ''), type: 'button',
      text: auto.on ? `Auto-scan: every ${auto.minutes} min, next in ${auto.nextIn}` : 'Auto-scan: off',
      title: 'Keep the data fresh from this server, as the scheduled collector would', onclick: toggleAutoScan
    }));
  } else if (auto.on) {
    kids.push(el('span', { class: 'fresh', text: `auto-scan every ${auto.minutes} min` }));
  }
  kids.push(el('span', { class: 'clock', text: L.clock }));
  kids.push(el('span', { class: 'who' }, S.me.user, el('span', { class: 'role ' + S.me.role, text: S.me.role }),
    el('button', { class: 'btn small', type: 'button', text: 'Password', title: 'Change your password', onclick: changePasswordDialog }),
    el('button', { class: 'btn small', type: 'button', text: 'Sign out', onclick: signOut })));
  setKids(top, ...kids);
}

function renderBanners() {
  const b = $('#banners');
  if (!b) return;
  const kids = [];
  if (S.me.insecure) kids.push(el('div', { class: 'banner warn', text: 'This connection is not encrypted (HTTP). Put the server behind an HTTPS reverse proxy, then use the https:// address.' }));
  if (S.live && !S.live.credential.ok && S.live.credential.note) kids.push(el('div', { class: 'banner crit', text: 'The server cannot reach kiosks: ' + S.live.credential.note }));
  if (S.live && !S.live.kioskList) {
    kids.push(el('div', { class: 'banner warn' }, 'There is no kiosk list yet, so there is nothing to scan. ',
      can('settings') ? el('button', { class: 'btn small', type: 'button', text: 'Upload one in Settings', onclick: () => show('Settings') }) : 'Ask an admin to upload one.'));
  }
  setKids(b, ...kids);
}

function tabKiosks(tab) {
  if (!S.fleet || !S.fleet.Ok) return [];
  return S.fleet.Kiosks.filter((k) => k.Tab === tab || (k.Tabs || []).includes(tab));
}

function renderNav() {
  const nav = $('#nav');
  if (!nav) return;
  const f = S.fleet;
  const tabs = f && f.Ok ? f.Tabs : {};
  const item = (id, label, badge, cls) => el('button', {
    type: 'button', class: S.view === id ? 'on' : '', 'aria-current': S.view === id ? 'page' : null,
    onclick: () => show(id)
  }, label, badge ? el('span', { class: 'badge' + (cls ? ' ' + cls : ''), text: String(badge) }) : null);

  const kids = [item('Overview', 'Overview')];
  kids.push(item('Mach2', 'Mach2', tabs.Mach2 && tabs.Mach2.Attention));
  kids.push(item('PBI', 'Power BI', tabs.PBI && tabs.PBI.Attention));
  if ((tabs.Web && tabs.Web.Count) || S.view === 'Web') kids.push(item('Web', 'Web pages', tabs.Web && tabs.Web.Attention));
  if ((tabs.Other && tabs.Other.Count) || S.view === 'Other') kids.push(item('Other', 'Other', tabs.Other && tabs.Other.Attention));
  kids.push(el('hr'));
  if (can('deploy')) kids.push(item('Deploy', 'Deploy'));
  kids.push(item('Activity', 'Activity', S.live && S.live.run ? (S.live.run.kind === 'scan' ? 'scanning' : 'running') : null, 'run'));
  if (can('audit')) kids.push(item('Audit', 'Audit log'));
  if (can('users') || can('settings')) kids.push(el('hr'));
  if (can('users')) kids.push(item('Users', 'Users'));
  if (can('settings')) kids.push(item('Settings', 'Settings'));
  kids.push(el('div', { class: 'ver', text: 'Kiosk Fleet Web ' + (S.me.version || '') }));
  setKids(nav, ...kids);
}

function show(view, host) {
  const changedView = S.view !== view;
  S.view = view;
  if (host !== undefined) S.selected = host;
  if (changedView && ['Mach2', 'PBI', 'Web', 'Other'].includes(view)) S.sort = { key: null, dir: 1 };
  renderNav();
  renderView(true, changedView);
  if (view === 'Activity') { loadReports(); pollRun(); }
  if (view === 'Audit') loadAudit();
  if (view === 'Users') loadUsers();
  if (view === 'Settings') loadSettings();
}

// The views keep their inputs between redraws (a filter being typed must
// not lose its caret every five seconds), so each is built once and then
// only its moving parts are redrawn.
function renderView(dataChanged, fresh) {
  const main = $('#main');
  if (!main || !S.live) return;
  if (main.dataset.view !== S.view || fresh) {
    main.dataset.view = S.view;
    setKids(main);
    main.scrollTop = 0;
    dataChanged = true;
  }
  switch (S.view) {
    case 'Overview': return renderOverview(main);
    case 'Mach2': case 'PBI': case 'Web': case 'Other': return renderKiosks(main);
    case 'Deploy': return renderDeploy(main, dataChanged);
    case 'Activity': return renderActivity(main);
    case 'Audit': return renderAudit(main);
    case 'Users': return renderUsers(main);
    case 'Settings': return renderSettings(main);
  }
}

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------
function renderOverview(main) {
  const f = S.fleet;
  if (!f || !f.Ok) {
    setKids(main, el('h2', { text: 'Overview' }), el('div', { class: 'card empty', text: f ? f.Error : 'Reading the fleet...' }));
    return;
  }
  const stat = (label, n, note, sev) => el('div', { class: 'card stat' },
    el('div', { class: 'l', text: label }), el('div', { class: 'n' + (sev ? ' sev-' + sev : ''), text: String(n) }), el('div', { class: 'note', text: note }));
  const web = f.Tabs.Web.Count;
  const stats = el('div', { class: 'stats' },
    stat('KIOSKS', f.Total, `${f.Tabs.Mach2.Count} Mach2, ${f.Tabs.PBI.Count} Power BI${web ? `, ${web} web page` : ''}${f.Inactive ? `, ${f.Inactive} not watched` : ''}`),
    stat('NEED ATTENTION', f.Attention, f.Attention ? `${f.Critical} critical` : 'nothing to do', f.Attention ? 'CRITICAL' : 'OK'),
    stat('REBOOTS 24H', f.Reboots24, f.Script24 ? `${f.Script24} by the watchdog` : 'none by the watchdog'),
    stat('SCREEN EVENTS 24H', f.Episodes24, 'white or blank screens'),
    stat('NEW LAUNCHERS', f.Launchers.Ng + f.Launchers.Pbi + f.Launchers.Web, `${f.Launchers.Ng} Mach2 NG, ${f.Launchers.Pbi} PBI Launcher${f.Launchers.Web ? `, ${f.Launchers.Web} Web Launcher` : ''}`));

  const attention = f.Kiosks.filter((k) => k.Attention);
  let att;
  if (!attention.length) att = el('div', { class: 'card empty sev-OK', text: 'Every kiosk is fine.' });
  else {
    att = el('div', { class: 'tablewrap' }, el('table', null,
      el('thead', null, el('tr', null, ['KIOSK', 'LOCATION', 'TYPE', 'STATUS', 'LAUNCHER', 'DETAIL'].map((h) => el('th', { class: 'nosort', text: h })))),
      el('tbody', null, attention.map((k) => {
        const lv = k.Launchers[k.Tab] || k.Launchers.Other;
        return el('tr', { onclick: () => show(k.Tab, k.Host), title: 'Open ' + k.Host },
          el('td', { class: 'host', text: k.Host }), el('td', { text: k.Location }), el('td', { text: k.Type }),
          el('td', null, pill(k.Status, k.Severity)), el('td', { class: 'sev-' + lv.Severity, text: lv.State }),
          el('td', { class: 'dim', text: k.Note, title: k.Note }));
      }))));
  }

  const max = Math.max(1, ...f.Chart.map((d) => d.Count));
  const chart = el('div', { class: 'chart', role: 'img', 'aria-label': 'Reboots per day, last seven days' },
    f.Chart.map((d) => el('div', { class: 'col', title: `${d.Long}: ${d.Count} reboot(s)` },
      el('span', { class: 'c', text: d.Count ? String(d.Count) : '' }),
      el('div', { class: 'bar', style: { height: Math.max(2, Math.round(90 * d.Count / max)) + 'px' } }),
      el('span', { class: 'd', text: d.Label }))));

  const c = f.Collector;
  const kv = (k, v, cls) => [el('div', { class: 'k', text: k }), el('div', { class: 'v' + (cls ? ' ' + cls : ''), text: v })];
  const collector = el('div', { class: 'kv' },
    kv('Last scan', S.live.fresh.lastRun, S.live.fresh.stale ? 'sev-CRITICAL' : ''),
    c ? [kv('Took', c.Took + 's'), kv('Reached', `${c.Reachable} of ${c.Hosts} kiosks`), kv('New events', String(c.NewEvents)), kv('Collector', 'v' + c.Version), kv('Ran as', c.Runner, 'dim')] : null,
    kv('Events file', f.File, 'dim'), kv('Rows', String(f.RowCount), 'dim'));

  setKids(main, 
    el('h2', { text: 'Overview' }),
    el('p', { class: 'sub', text: 'Everything needing attention first. The tables are as of the last scan; Read live on a kiosk reads it now.' }),
    stats,
    el('div', { class: 'ov' },
      el('div', null, el('h3', { text: 'NEEDS ATTENTION' }), att),
      el('div', null,
        el('h3', { text: 'REBOOTS, LAST 7 DAYS' }), el('div', { class: 'card' }, chart),
        el('h3', { text: 'COLLECTION' }), el('div', { class: 'card' }, collector))));
}

// ---------------------------------------------------------------------------
// The kiosk tabs
// ---------------------------------------------------------------------------
const COLS = {
  host: { h: 'KIOSK', v: (k) => k.Host, cls: 'host' },
  type: { h: 'TYPE', v: (k) => k.Type },
  location: { h: 'LOCATION', v: (k) => k.Location },
  status: { h: 'STATUS', v: (k) => k.Status, sortv: (k) => k.Rank, cell: (k) => pill(k.Status, k.Severity) },
  launcher: { h: 'LAUNCHER', v: (k, lv) => lv.State, sev: (k, lv) => lv.Severity },
  for: { h: 'FOR', v: (k, lv) => lv.For },
  screen: { h: 'SCREEN', v: (k, lv) => lv.Screen, title: 'How white the screen is' },
  account: { h: 'SIGNED IN AS', v: (k, lv) => lv.Account, sev: (k) => (k.Status === 'WRONG_ACCOUNT' ? 'CRITICAL' : 'DIM') },
  ver: { h: 'VER', v: (k, lv) => lv.Version },
  watchdog: { h: 'WATCHDOG', v: (k) => k.Watchdog, sev: (k) => (k.Watchdog === 'DEAD' ? 'CRITICAL' : 'DIM') },
  log: { h: 'LOG', v: (k) => k.LogAge, title: 'Minutes since the watchdog last wrote' },
  agent: { h: 'AGENT', v: (k) => k.Agent },
  uptime: { h: 'UPTIME', v: (k) => k.Uptime },
  reb: { h: 'REB 24H', v: (k) => k.Reboots, sortv: (k) => k.Reboots24 * 1000 + k.Script24, title: 'Reboots in 24 hours (by the watchdog)' },
  days: { h: '7 DAYS', v: (k) => k.Days.join(','), sortv: (k) => k.Days.reduce((a, b) => a + b, 0), cell: (k, lv, max) => spark(k.Days, max) }
};
const TAB_COLS = {
  Mach2: ['host', 'location', 'status', 'launcher', 'screen', 'watchdog', 'log', 'agent', 'uptime', 'reb', 'days'],
  PBI: ['host', 'location', 'status', 'launcher', 'for', 'account', 'ver', 'uptime'],
  Web: ['host', 'location', 'status', 'launcher', 'for', 'ver', 'uptime'],
  Other: ['host', 'type', 'location', 'status', 'uptime']
};

function spark(days, max) {
  return el('span', { class: 'spark', title: days.join(' / ') + ' reboots, oldest first' },
    days.map((n) => (n > 0 ? el('i', { style: { height: Math.max(3, Math.round(14 * n / Math.max(1, max))) + 'px' } }) : el('i', { class: 'z' }))));
}

function matchesFilter(k, lv, text) {
  if (!text) return true;
  const t = text.trim().toLowerCase();
  if (!t) return true;
  return [k.Host, k.Location, k.Status, k.Type, lv.State, lv.Account].some((x) => x && x.toLowerCase().includes(t));
}

function renderKiosks(main) {
  const tab = S.view;
  if (!$('#ktool', main)) {
    const search = el('input', { type: 'search', id: 'kfilter', placeholder: 'Filter: name, location, status, account', value: S.filter, 'aria-label': 'Filter kiosks' });
    search.addEventListener('input', () => { S.filter = search.value; renderKioskTable(); });
    const only = el('input', { type: 'checkbox', checked: S.onlyProblems });
    only.addEventListener('change', () => { S.onlyProblems = only.checked; renderKioskTable(); });
    main.append(
      el('h2', { id: 'ktitle' }), el('p', { class: 'sub', id: 'ksub' }),
      el('div', { class: 'toolbar', id: 'ktool' }, search, el('label', { class: 'check' }, only, 'Only those needing attention'),
        can('deploy') ? el('button', { class: 'btn small', type: 'button', text: 'Deploy to this tab...', onclick: () => openDeployFor(null, TAB_KIND[tab] || 'NG') }) : null),
      el('div', { class: 'split' }, el('div', { id: 'ktable' }), el('aside', { class: 'card detail', id: 'kdetail', 'aria-live': 'polite' })));
  }
  const kiosks = tabKiosks(tab);
  $('#ktitle', main).textContent = TAB_TITLE[tab];
  $('#ksub', main).textContent = `${kiosks.length} kiosks, ${kiosks.filter((k) => k.Attention).length} needing attention`;
  renderKioskTable();
  renderDetail();
}

function renderKioskTable() {
  const box = $('#ktable');
  if (!box) return;
  const tab = S.view;
  const all = tabKiosks(tab);
  const cols = TAB_COLS[tab].map((id) => Object.assign({ id }, COLS[id]));
  const lvOf = (k) => k.Launchers[tab] || k.Launchers.Other;
  let rows = all.filter((k) => (!S.onlyProblems || k.Attention) && matchesFilter(k, lvOf(k), S.filter));
  if (S.sort.key) {
    const c = COLS[S.sort.key];
    const key = (k) => (c.sortv ? c.sortv(k) : c.v(k, lvOf(k)) || '');
    rows = rows.slice().sort((a, b) => {
      const x = key(a), y = key(b);
      const r = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y), undefined, { numeric: true });
      return r * S.sort.dir;
    });
  }
  if (!all.length) { setKids(box, el('div', { class: 'card empty', text: S.fleet && S.fleet.Ok ? `No ${tab} kiosks in the data.` : 'Reading the fleet...' })); return; }
  if (!rows.length) { setKids(box, el('div', { class: 'card empty', text: S.onlyProblems ? 'Nothing on this tab needs attention.' : 'Nothing matches the filter.' })); return; }

  const max = Math.max(1, ...all.flatMap((k) => k.Days));
  const busy = S.live.busy || {};
  const head = el('tr', null, cols.map((c) => {
    const on = S.sort.key === c.id;
    return el('th', {
      title: c.title || 'Sort', scope: 'col', 'aria-sort': on ? (S.sort.dir > 0 ? 'ascending' : 'descending') : null,
      onclick: () => { S.sort = { key: c.id, dir: on ? -S.sort.dir : 1 }; renderKioskTable(); }
    }, c.h, on ? el('span', { class: 'arrow', text: S.sort.dir > 0 ? ' ▲' : ' ▼' }) : null);
  }));
  const body = el('tbody', null, rows.map((k) => {
    const lv = lvOf(k);
    const tr = el('tr', { class: (k.Host === S.selected ? 'sel' : '') + (busy[k.Host] ? ' busy' : ''), tabindex: '0' },
      cols.map((c) => {
        if (c.cell) return el('td', null, c.cell(k, lv, max));
        const v = c.v(k, lv) || '';
        return el('td', { class: [c.cls, c.sev ? 'sev-' + c.sev(k, lv) : ''].filter(Boolean).join(' '), text: v, title: v.length > 30 ? v : null });
      }));
    const pick = () => { S.selected = k.Host; renderKioskTable(); renderDetail(); };
    tr.addEventListener('click', pick);
    tr.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(); } });
    return tr;
  }));
  setKids(box, el('div', { class: 'tablewrap' }, el('table', null, el('thead', null, head), body)));
}

function getKiosk(host) {
  return S.fleet && S.fleet.Ok ? S.fleet.Kiosks.find((k) => k.Host === host) : null;
}

function screenTarget(k) {
  const c = S.screenChoice[k.Host] || '';
  const m = /^(S\d+)\|(NG|PBI|WEB)$/.exec(c);
  return m ? { screen: m[1], kind: m[2] } : { screen: '', kind: 'ALL' };
}

function renderDetail() {
  const box = $('#kdetail');
  if (!box) return;
  // A screen box someone is choosing from is not pulled from under them.
  if (box.contains(document.activeElement) && document.activeElement.tagName === 'SELECT') return;
  const k = S.selected ? getKiosk(S.selected) : null;
  if (!k || !(k.Tab === S.view || (k.Tabs || []).includes(S.view))) {
    setKids(box, el('div', { class: 'empty', text: 'Pick a kiosk to see its details and what can be done to it.' }));
    return;
  }
  const L = S.live;
  const busy = (L.busy || {})[k.Host];
  const kids = [
    el('div', { class: 'head' },
      el('div', null, el('div', { class: 'host', text: k.Host }), el('div', { class: 'dim', text: [k.Location, k.Type].filter(Boolean).join('  |  ') })),
      pill(k.Status, k.Severity)),
    busy ? el('div', { class: 'busy', text: 'Busy: ' + busy + ' ...' }) : null
  ];
  const row = (r) => el('div', { class: 'row' }, el('span', { class: 'k', text: r.Label }), el('span', { class: 'v sev-' + (r.Sev || 'TEXT'), text: r.Value }));
  for (const s of k.Detail) kids.push(el('h3', { text: s.Title }), s.Rows.map(row));

  const live = (L.live || {})[k.Host];
  if (live) kids.push(el('h3', { text: 'READ LIVE AT ' + live.At }), live.Lines.map(row));

  const snap = (L.snapshots || {})[k.Host];
  if (snap) {
    kids.push(el('h3', { text: 'SCREENSHOT' }),
      el('a', { href: '/api/snapshots/' + encodeURIComponent(snap.File), target: '_blank', rel: 'noopener', title: 'Open full size' },
        el('img', { class: 'snap', src: '/api/snapshots/' + encodeURIComponent(snap.File), alt: 'What was on the screen of ' + k.Host })),
      el('div', { class: 'hint', text: snap.Caption }));
  }

  if (k.Screens.length > 1) {
    const sel = el('select', { 'aria-label': 'Which screen the launcher buttons act on' },
      el('option', { value: '', text: 'All screens' }),
      k.Screens.map((s) => el('option', { value: `${s.Screen}|${s.Kind}`, text: `${s.Screen}  -  ${s.Name}  (${s.State})` })));
    sel.value = S.screenChoice[k.Host] || '';
    sel.addEventListener('change', () => { S.screenChoice[k.Host] = sel.value; renderDetail(); });
    kids.push(el('h3', { text: 'SCREEN' }), sel);
  }
  kids.push(renderActions(k, !!busy));
  setKids(box, ...kids);
}

function renderActions(k, busy) {
  const target = screenTarget(k);
  const onlyWeb = target.kind === 'WEB' || (target.kind === 'ALL' && k.Screens.length > 0 && k.Screens.every((s) => s.Kind === 'WEB'));
  const hold = !!(S.live.hold || {})[k.Host];
  const b = (text, what, fn, opts) => {
    opts = opts || {};
    if (!can(what)) return null;
    return el('button', {
      type: 'button', class: 'btn small' + (opts.danger ? ' danger' : ''), text,
      disabled: busy || opts.disabled, title: opts.title || null, onclick: () => fn(k)
    });
  };
  const noLauncher = !k.HasLauncher ? 'This kiosk is not on the new launcher yet' : null;
  const kiosk = [
    b('Restart...', 'restart', restartDialog),
    can('view') ? el('button', { type: 'button', class: 'btn small', text: 'Remote control', onclick: () => remoteControl(k) }) : null,
    b('Message...', 'message', messageDialog, { disabled: !k.MessageOk, title: k.MessageWhy || 'A window on the kiosk screen, put up by its watchdog' }),
    el('button', { type: 'button', class: 'btn small', text: 'Open share', onclick: () => openShare(k) })
  ];
  const launcher = [
    b('Read live', 'live', (x) => runKioskJob(x, 'live', {}, { title: 'reading' })),
    b('Screenshot', 'snapshot', (x) => runKioskJob(x, 'snapshot', {}, { title: 'asking for a screenshot' }), { disabled: !k.HasLauncher, title: noLauncher }),
    b('Reload', 'reload', (x) => runKioskJob(x, 'reload', {}, { title: 'reloading the page' }), { disabled: !k.HasLauncher, title: noLauncher }),
    b('Restart browser', 'relaunch', (x) => runKioskJob(x, 'relaunch', {}, { title: 'restarting the browser' }), { disabled: !k.HasLauncher, title: noLauncher }),
    hold ? b('Resume', 'resume', (x) => runKioskJob(x, 'resume', {}, { title: 'carrying on' }), { disabled: !k.HasLauncher })
      : b('Hold', 'hold', holdDialog, { disabled: !k.HasLauncher, title: noLauncher }),
    b('Stop', 'stop', stopDialog, { danger: true, disabled: !k.HasLauncher, title: noLauncher }),
    b('Log', 'log', logDialog, { disabled: !k.HasLauncher, title: noLauncher }),
    b('Password...', 'password', passwordDialog, { disabled: !k.HasLauncher || onlyWeb, title: onlyWeb ? 'A web page screen signs in to nothing' : noLauncher }),
    b('Config...', 'config', openKioskConfig, { title: k.HasLauncher ? "The kiosk's own settings: URL, account, screen, refresh" : 'No launcher here yet - this writes the config a deploy needs' }),
    b('Add screen...', 'config', (x) => instancePicker(x, true)),
    b('Deploy command...', 'deploy', (x) => openDeployFor(x.Host, target.screen ? target.kind : (S.view === 'Web' ? 'WEB' : (S.view === 'PBI' || x.Tab === 'PBI' ? 'PBI' : 'NG'))))
  ];
  return el('div', { class: 'actions' },
    el('h3', { text: 'KIOSK' }), el('div', { class: 'btnrow' }, kiosk),
    el('h3', { text: 'LAUNCHER' + (target.screen ? ` - ${target.screen} ${NAMES[target.kind]}` : '') }), el('div', { class: 'btnrow' }, launcher),
    S.me.role === 'operator' ? el('p', { class: 'hint', text: 'Restart, hold, stop, passwords, config and deploys are for admins.' }) : null);
}

// ---------------------------------------------------------------------------
// The card: one modal, dressed for whatever is being asked
// ---------------------------------------------------------------------------
function closeModal() {
  if (S.modal) { S.modal.root.remove(); S.modal = null; }
}

function openModal(o) {
  closeModal();
  const controls = {};
  const fields = el('div');
  const adv = el('div', { class: 'adv hidden' });
  let hasAdv = false;
  for (const f of o.fields || []) {
    const target = f.advanced ? adv : fields;
    if (f.advanced) hasAdv = true;
    if (f.kind === 'note') { target.append(el('div', { class: 'h', text: f.label })); continue; }
    const id = 'f_' + Math.random().toString(36).slice(2);
    let control, wrap;
    switch (f.kind) {
      case 'password': {
        const p1 = el('input', { type: 'password', id, autocomplete: 'new-password', maxLength: 256 });
        const p2 = el('input', { type: 'password', autocomplete: 'new-password', maxLength: 256, 'aria-label': f.label + ' again' });
        controls[f.key] = { kind: 'password', p1, p2 };
        wrap = el('div', { class: 'field' }, el('label', { class: 'lbl', for: id, text: f.label }), p1,
          el('span', { class: 'lbl', style: { marginTop: '8px' }, text: 'again' }), p2);
        break;
      }
      case 'secret': {
        control = el('input', { type: 'password', id, autocomplete: 'current-password', maxLength: 256 });
        controls[f.key] = { kind: 'secret', c: control };
        wrap = el('div', { class: 'field' }, el('label', { class: 'lbl', for: id, text: f.label }), control);
        break;
      }
      case 'bool': {
        control = el('input', { type: 'checkbox', id, checked: ['1', 'true', 'True'].includes(String(f.value)) });
        controls[f.key] = { kind: 'bool', c: control };
        wrap = el('div', { class: 'field' }, el('span', { class: 'lbl', text: f.label }), el('label', { class: 'check', for: id }, control, f.hint || 'on'));
        break;
      }
      case 'choice': {
        control = el('select', { id }, (f.options || []).map((op) => el('option', { value: op.value, text: op.text })));
        if (f.value) control.value = f.value;
        controls[f.key] = { kind: 'text', c: control };
        wrap = el('div', { class: 'field' }, el('label', { class: 'lbl', for: id, text: f.label }), control);
        break;
      }
      case 'textarea': {
        control = el('textarea', { id, rows: 3, maxLength: f.max || 1000 });
        control.value = f.value || '';
        controls[f.key] = { kind: 'text', c: control };
        wrap = el('div', { class: 'field' }, el('label', { class: 'lbl', for: id, text: f.label }), control);
        break;
      }
      default: {
        control = el('input', { type: f.kind === 'number' ? 'number' : 'text', id, maxLength: f.max || 4000 });
        control.value = f.value == null ? '' : String(f.value);
        controls[f.key] = { kind: 'text', c: control };
        wrap = el('div', { class: 'field' }, el('label', { class: 'lbl', for: id, text: f.label }), control);
      }
    }
    if (f.hint && f.kind !== 'bool') wrap.append(el('div', { class: 'hint', text: f.hint }));
    target.append(wrap);
  }
  const note = el('div', { class: 'note', role: 'alert', text: o.note || '' });
  const log = el('pre', { class: 'log' + (o.withLog ? '' : ' hidden') });
  const ok = el('button', { type: 'button', class: 'btn ' + (o.danger ? 'danger' : 'primary'), text: o.okText || 'OK' });
  const cancel = el('button', { type: 'button', class: 'btn', text: o.okText === null ? 'Close' : 'Cancel', onclick: closeModal });
  if (o.okText === null) ok.classList.add('hidden');
  const more = hasAdv ? el('button', { type: 'button', class: 'btn small', text: 'More settings', onclick: () => { adv.classList.toggle('hidden'); } }) : null;
  const modal = el('div', { class: 'modal' + (o.wide ? ' wide' : ''), role: 'dialog', 'aria-modal': 'true', 'aria-label': o.title },
    el('h2', { text: o.title }), o.sub ? el('div', { class: 'dim', text: o.sub }) : null,
    o.body ? el('div', { class: 'body', text: o.body }) : null,
    o.extra || null,
    fields, more, adv, note, log,
    el('div', { class: 'foot' }, cancel, ok));
  const root = el('div', { class: 'overlay' }, modal);
  root.addEventListener('mousedown', (e) => { if (e.target === root && !m.working) closeModal(); });
  document.body.append(root);

  const m = {
    root, working: false,
    values() {
      const out = {};
      for (const [k, c] of Object.entries(controls)) {
        if (c.kind === 'password') { out[k] = c.p1.value; out[k + '.again'] = c.p2.value; }
        else if (c.kind === 'bool') out[k] = c.c.checked ? '1' : '0';
        else if (c.kind === 'secret') out[k] = c.c.value;
        else out[k] = c.c.value.trim();
      }
      return out;
    },
    clearSecrets() { for (const c of Object.values(controls)) { if (c.kind === 'password') { c.p1.value = ''; c.p2.value = ''; } else if (c.kind === 'secret') c.c.value = ''; } },
    setNote(text, sev) { note.textContent = text || ''; note.className = 'note' + (sev ? ' sev-' + sev : ''); },
    log(line) { log.classList.remove('hidden'); log.textContent += line + '\n'; log.scrollTop = log.scrollHeight; },
    setLog(lines) { log.classList.remove('hidden'); log.textContent = lines.join('\n'); },
    busy(on) { m.working = on; ok.disabled = on; },
    finish(text, sev) { m.working = false; ok.classList.add('hidden'); cancel.textContent = 'Close'; m.setNote(text, sev); cancel.focus(); },
    close: closeModal
  };
  ok.addEventListener('click', async () => {
    if (!o.onOk) return closeModal();
    m.setNote('');
    try {
      const keep = await o.onOk(m.values(), m);
      if (keep !== true && S.modal === m) closeModal();
    } catch (e) { m.busy(false); m.setNote(e.message, 'CRITICAL'); }
  });
  modal.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target.tagName === 'INPUT' && e.target.type !== 'checkbox') { e.preventDefault(); ok.click(); }
  });
  S.modal = m;
  const first = modal.querySelector('input, select, textarea');
  setTimeout(() => (first || (o.okText === null ? cancel : ok)).focus(), 0);
  return m;
}

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && S.modal && !S.modal.working) closeModal();
});

// ---------------------------------------------------------------------------
// Doing something to a kiosk: the server starts it and answers with a job;
// the page follows the job until it is done.
// ---------------------------------------------------------------------------
async function waitJob(id, onLine) {
  let seen = 0;
  for (;;) {
    const j = await api('GET', '/api/jobs/' + id);
    for (; seen < j.lines.length; seen++) if (onLine) onLine(j.lines[seen]);
    if (j.done) return j;
    await sleep(700);
  }
}

async function runKioskJob(k, action, body, o) {
  o = o || {};
  const target = screenTarget(k);
  const payload = Object.assign({}, action.startsWith('config') ? {} : { screen: target.screen, kind: target.screen ? target.kind : '' }, body || {});
  const m = o.modal;
  try {
    const r = await api('POST', `/api/kiosks/${encodeURIComponent(k.Host)}/${action}`, payload);
    refreshSoon();
    if (!m) toast(`${k.Host}: ${o.title || action} ...`, 'UNKNOWN', 4);
    const j = await waitJob(r.job, m ? (l) => m.log(l) : null);
    refreshSoon();
    const sev = j.ok ? (j.waiting ? 'WARNING' : 'OK') : 'CRITICAL';
    if (o.onDone) o.onDone(j, sev);
    else if (m) { m.log(j.detail); m.finish(j.detail, sev); }
    else toast(`${k.Host}: ${j.detail}`, sev, j.ok ? 6 : 10);
    return j;
  } catch (e) {
    if (m) m.finish(e.message, 'CRITICAL');
    else toast(`${k.Host}: ${e.message}`, 'CRITICAL', 10);
    return null;
  }
}

function restartDialog(k) {
  openModal({
    title: `Restart ${k.Host}?`, sub: [k.Location, k.Type].filter(Boolean).join('  |  '),
    body: 'The kiosk shows the message below, counts down, and then restarts. Anything running on it is closed. It comes back on its own.',
    fields: [
      { key: 'message', label: 'Message on the kiosk screen (empty for none)', value: S.live.restart.message, kind: 'textarea', max: 500 },
      { key: 'seconds', label: 'Countdown in seconds (0 restarts at once)', value: S.live.restart.seconds, kind: 'number' }
    ],
    okText: 'Restart the kiosk', danger: true, withLog: false,
    onOk: async (v, m) => {
      const secs = Number(v.seconds);
      if (!Number.isInteger(secs) || secs < 0 || secs > 3600) { m.setNote('The countdown has to be a whole number of seconds, 0 to 3600.', 'CRITICAL'); return true; }
      m.busy(true);
      m.log(`Restarting ${k.Host} ...`);
      runKioskJob(k, 'restart', { message: v.message, seconds: secs }, { modal: m });
      return true;
    }
  });
}

function messageDialog(k) {
  openModal({
    title: `Message on ${k.Host}`, sub: 'A window on the kiosk screen with an OK button and a countdown, put up by its watchdog.',
    fields: [
      { key: 'text', label: 'Message', kind: 'textarea', max: 1000 },
      { key: 'seconds', label: 'On screen for, at most, seconds', value: 60, kind: 'number' }
    ],
    okText: 'Show it',
    onOk: async (v, m) => {
      if (!v.text) { m.setNote('Type the message first.', 'CRITICAL'); return true; }
      const secs = Number(v.seconds);
      if (!Number.isInteger(secs) || secs < 5 || secs > 900) { m.setNote('Between 5 and 900 seconds.', 'CRITICAL'); return true; }
      m.busy(true);
      runKioskJob(k, 'message', { text: v.text, seconds: secs }, { modal: m });
      return true;
    }
  });
}

function holdDialog(k) {
  openModal({
    title: `Hold ${k.Host}?`,
    body: 'Hold leaves the screen exactly as it is: no checks, no reloads, no sign-in, and no restarts from the watchdog until you resume. The kiosk keeps showing whatever is on it now.',
    okText: 'Hold',
    onOk: async () => { runKioskJob(k, 'hold', {}, { title: 'holding' }); }
  });
}

function stopDialog(k) {
  openModal({
    title: `Stop the launcher on ${k.Host}?`,
    body: 'Stop closes the browser and ends the launcher. The screen stays empty until the kiosk restarts or its user logs on again. On a Mach2 kiosk that also stops the watchdog, so nothing is watching the screen.',
    okText: 'Stop the launcher', danger: true,
    onOk: async () => { runKioskJob(k, 'stop', {}, { title: 'stopping the launcher' }); }
  });
}

function logDialog(k) {
  const m = openModal({ title: `${k.Host} - launcher log`, sub: 'The end of the log the launcher writes on the kiosk.', okText: null, withLog: true, wide: true });
  m.log('reading ...');
  m.working = true;
  runKioskJob(k, 'log', {}, {
    modal: m,
    onDone: (j, sev) => {
      m.working = false;
      if (j.ok && j.result) { m.setLog(j.result.lines); m.setNote(j.result.path, 'DIM'); }
      else m.finish(j.detail, sev);
    }
  });
}

function passwordDialog(k) {
  const t = screenTarget(k);
  const who = t.kind === 'PBI' ? 'the Power BI account' : t.kind === 'NG' ? 'the Mach2 station account' : "every screen's sign-in account (not the web pages')";
  openModal({
    title: `Sign-in password for ${k.Host}`,
    sub: `The new password for ${who}. The launcher encrypts it for the kiosk account, checks it reads back, and wipes what you typed.`,
    fields: [{ key: 'password', label: 'New password', kind: 'password' }],
    note: 'Only the password changes; the account stays the one in the kiosk config.',
    okText: 'Hand it over',
    onOk: async (v, m) => {
      if (!v.password) { m.setNote('Type the password first.', 'CRITICAL'); return true; }
      if (v.password !== v['password.again']) { m.setNote('The two did not match. Nothing was changed.', 'CRITICAL'); return true; }
      m.busy(true);
      m.clearSecrets();
      m.log('writing password.seed ...');
      runKioskJob(k, 'password', { password: v.password, password2: v['password.again'] }, { modal: m });
      return true;
    }
  });
}

function remoteControl(k) {
  const site = S.live.remoteControl;
  const cmd = `CmRcViewer.exe ${k.Host}${site ? ' \\\\' + site : ''}`;
  openModal({
    title: `Remote control ${k.Host}`,
    body: 'SCCM remote control runs on your own PC, not on this server. With the Configuration Manager console installed, run:',
    extra: el('div', null, el('pre', { class: 'cmd', text: cmd }), el('div', { style: { marginTop: '8px' } }, el('button', { class: 'btn small', type: 'button', text: 'Copy', onclick: () => copyText(cmd) }))),
    okText: null
  });
}

function openShare(k) {
  const tpl = S.live.rootTemplate || '\\\\{0}\\C$';
  const path = tpl.replace('{0}', k.Host) + '\\Users\\Public\\Documents';
  openModal({
    title: `${k.Host} - the kiosk's share`,
    body: 'The launchers keep their configs, status and logs here. Open it in Explorer from your own PC (it needs admin rights on the kiosk):',
    extra: el('div', null, el('pre', { class: 'cmd', text: path }), el('div', { style: { marginTop: '8px' } }, el('button', { class: 'btn small', type: 'button', text: 'Copy', onclick: () => copyText(path) }))),
    okText: null
  });
}

// --- the kiosk's own settings ---------------------------------------------
function openKioskConfig(k) {
  const t = screenTarget(k);
  if (t.screen) return configEditor(k.Host, t.kind, t.screen);
  if (k.Screens.length === 1) return configEditor(k.Host, k.Screens[0].Kind, k.Screens[0].Screen);
  if (k.Screens.length === 0) return configEditor(k.Host, TAB_KIND[k.Tab] || TAB_KIND[S.view] || 'NG', '');
  instancePicker(k, false);
}

function instancePicker(k, newOnly) {
  const screens = k ? k.Screens : [];
  const options = [];
  if (!newOnly) for (const s of screens) options.push({ value: `${s.Screen}|${s.Kind}`, text: `${s.Screen}  -  ${s.Name}  (${s.State})` });
  const used = screens.map((s) => parseInt(s.Screen.slice(1), 10));
  let next = 1;
  while (used.includes(next)) next++;
  for (const kind of ['NG', 'PBI', 'WEB']) options.push({ value: `S${next}|${kind}|new`, text: `New screen S${next}  -  ${NAMES[kind]}` });
  const def = !newOnly && screens.length ? options[0].value : (k && TAB_KIND[k.Tab] && !screens.length ? `S1|${TAB_KIND[k.Tab]}|new` : options[0].value);
  openModal({
    title: `Which screen on ${k.Host}?`,
    sub: 'Each screen has its own config and its own launcher: Mach2 dashboard, Power BI report or a web page.',
    fields: [{ key: 'pick', label: 'Screen', kind: 'choice', value: def, options }],
    note: "A new screen gets its config from the launcher's EXAMPLE.json. Deploy that launcher afterwards to start it.",
    okText: 'Open it',
    onOk: async (v) => {
      const m = /^(S\d+)\|(NG|PBI|WEB)/.exec(v.pick);
      if (m) configEditor(k.Host, m[2], m[1]);
      return true;
    }
  });
}

async function configEditor(host, kind, instance) {
  const m = openModal({ title: `Config for ${host}`, sub: 'reading the kiosk ...', okText: null, withLog: true });
  m.working = true;
  let j;
  try {
    const r = await api('POST', `/api/kiosks/${encodeURIComponent(host)}/config-read`, { kind, instance });
    j = await waitJob(r.job, (l) => m.log(l));
  } catch (e) { m.finish(e.message, 'CRITICAL'); return; }
  m.working = false;
  if (!j.ok || !j.result) { m.finish(j.detail, 'CRITICAL'); return; }
  const c = j.result;
  const where = `screen ${c.instance}, ${NAMES[c.kind]}`;
  let sub = c.isNew
    ? `No config on the kiosk yet: this is EXAMPLE.json, for you to fill in. Saving it writes ${host}.json, which is what a new kiosk needs before a deploy will install anything.`
    : `The launcher reads its config every few seconds, so a change applies without a restart. Password: ${c.password}.`;
  if (c.instances.length > 1) sub += `  This kiosk has ${c.instances.join(', ')}; this is ${c.instance}.`;
  const taken = c.taken || {};
  const fields = c.fields.map((f) => ({ key: f.Key, label: f.Label, value: f.Value, kind: f.Kind, hint: f.Hint, advanced: f.Advanced }));
  if (c.isNew) {
    const t = Object.keys(taken).sort().map((s) => `${s} (${NAMES[taken[s]]})`);
    fields.unshift({ key: '__instance', label: 'Screen folder', value: c.instance, hint: 'S1 is the first screen, S2 the second, each with its own config.' + (t.length ? ' Taken already: ' + t.join(', ') + '.' : '') });
  }
  const required = c.kind === 'WEB' ? ['DisplayURL'] : ['DisplayURL', 'UserName'];
  openModal({
    title: `${host} - ${where}`, sub, fields, withLog: false, wide: true,
    okText: c.isNew ? 'Write it to the kiosk' : 'Save to the kiosk',
    onOk: async (v, mm) => {
      if ((v.__password || '') !== (v['__password.again'] || '')) { mm.setNote('The two passwords did not match. Nothing was saved.', 'CRITICAL'); return true; }
      const missing = required.filter((r) => !v[r]);
      if (missing.length) { mm.setNote('Still empty: ' + missing.join(', ') + '.', 'CRITICAL'); return true; }
      let inst = c.instance;
      if (c.isNew) {
        inst = (v.__instance || '').toUpperCase();
        if (!/^S\d{1,2}$/.test(inst)) { mm.setNote('A screen folder is named like S1 or S2.', 'CRITICAL'); return true; }
        if (taken[inst]) { mm.setNote(`${inst} shows ${NAMES[taken[inst]]} already - one launcher per screen. Pick another screen folder.`, 'CRITICAL'); return true; }
      }
      const values = {};
      for (const f of c.fields) if (f.Kind !== 'password') values[f.Key] = v[f.Key];
      const body = { kind: c.kind, instance: inst, values, password: v.__password || '', password2: v['__password.again'] || '' };
      mm.busy(true);
      mm.clearSecrets();
      mm.log(`writing ${host}.json to ${inst} ...`);
      try {
        const r = await api('POST', `/api/kiosks/${encodeURIComponent(host)}/config-write`, body);
        const jj = await waitJob(r.job, (l) => mm.log(l));
        refreshSoon();
        mm.finish(jj.detail, jj.ok ? 'OK' : 'CRITICAL');
        if (jj.ok) toast(`${host}: config saved.`, 'OK');
      } catch (e) { mm.finish(e.message, 'CRITICAL'); }
      return true;
    }
  });
}

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------
async function scanNow() {
  try { await api('POST', '/api/scan'); toast('Scan started - its output is in Activity.', 'OK', 4); refreshSoon(); }
  catch (e) { toast(e.message, 'WARNING', 8); }
}

async function toggleAutoScan() {
  try { await api('POST', '/api/autoscan', { on: !S.live.autoscan.on }); refreshSoon(); }
  catch (e) { toast(e.message, 'WARNING', 10); }
}

// ---------------------------------------------------------------------------
// Deploy
// ---------------------------------------------------------------------------
async function loadProducts() {
  if (!can('deploy') || S.products.length) return;
  try { S.products = (await api('GET', '/api/deploy/products')).products; } catch (e) { return; }
  if (S.view === 'Deploy' && $('#dform')) { renderDeployForm(); renderDeployTargets(); updatePreview(); }
}

function productInfo(id) { return S.products.find((p) => p.id === id) || { id, name: id, tab: 'Mach2', note: '' }; }

function openDeployFor(host, product) {
  const d = S.deploy;
  d.product = product;
  if (host) d.ticks = new Set([host]);
  show('Deploy');
}

function deployTargets() {
  const d = S.deploy;
  const info = productInfo(d.product);
  const kiosks = info.tab === '*' ? (S.fleet && S.fleet.Ok ? S.fleet.Kiosks : []) : tabKiosks(info.tab);
  const rows = kiosks.map((k) => ({ host: k.Host, location: k.Location, status: k.Status, sev: k.Severity, note: k.DeployNotes[d.product] || '' }));
  const written = new Set(S.live.configWritten || []);
  for (const x of d.extra[d.product]) {
    if (rows.some((r) => r.host === x)) continue;
    rows.push({ host: x, location: '', status: 'NOT SCANNED', sev: 'INACTIVE', note: written.has(x) ? 'config written, launcher not installed' : 'not in the last scan' });
  }
  return rows;
}

function deployBody() {
  const d = S.deploy;
  return Object.assign({ product: d.product, rollback: d.rollback, hosts: [...d.ticks].sort() }, d.opts,
    { warnSeconds: Number(d.opts.warnSeconds), verifyMinutes: Number(d.opts.verifyMinutes) });
}

let previewTimer = null;
function updatePreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(async () => {
    const pre = $('#dpreview'), note = $('#dnote');
    if (!pre) return;
    const d = S.deploy;
    const ok = d.ticks.size > 0;
    $('#dcopy').disabled = !ok;
    if (!ok) { pre.textContent = '(tick the kiosks to deploy to)'; note.textContent = 'Start with one kiosk.'; note.className = 'hint'; d.preview = ''; return; }
    try {
      const r = await api('POST', '/api/deploy/preview', deployBody());
      d.preview = r.command;
      pre.textContent = r.preview;
      const what = d.rollback ? 'Roll back' : 'Install or update';
      note.textContent = `${what} on ${d.ticks.size} kiosk${d.ticks.size === 1 ? '' : 's'}.` + (d.opts.dryRun ? ' As a dry run (-WhatIf) it changes nothing - untick it for the real thing.' : (d.opts.restart ? ' Each one restarts, one at a time, and the first failure stops the run.' : ' It takes effect at the next logon.'));
      note.className = 'hint';
    } catch (e) {
      d.preview = '';
      pre.textContent = '';
      note.textContent = e.message;
      note.className = 'hint sev-CRITICAL';
      $('#dcopy').disabled = true;
    }
  }, 200);
}

function renderDeploy(main, dataChanged) {
  if (!can('deploy')) { setKids(main, el('div', { class: 'card empty', text: 'Deploys are for admins.' })); return; }
  const d = S.deploy;
  if ($('#dform', main) && !dataChanged) return;
  if (!$('#dform', main)) {
    const prodSeg = el('div', { class: 'seg', id: 'dprod', role: 'radiogroup', 'aria-label': 'What to install' });
    const modeSeg = el('div', { class: 'seg', id: 'dmode', role: 'radiogroup', 'aria-label': 'Install or roll back' });
    const filter = el('input', { type: 'search', placeholder: 'Filter', value: d.filter, 'aria-label': 'Filter kiosks' });
    filter.addEventListener('input', () => { d.filter = filter.value; renderDeployTargets(); });
    const opt = (key, label, id) => {
      const c = el('input', { type: 'checkbox', checked: !!d.opts[key] });
      c.addEventListener('change', () => { d.opts[key] = c.checked; updatePreview(); });
      return el('label', { class: 'check', id }, c, label);
    };
    const num = (key, label, id) => {
      const i = el('input', { type: 'number', value: String(d.opts[key]) });
      i.addEventListener('input', () => { d.opts[key] = i.value; updatePreview(); });
      return el('label', { id }, el('span', { class: 'lbl', text: label }), i);
    };
    const user = el('input', { type: 'text', value: d.opts.kioskUser, maxLength: 104, placeholder: 'worked out by the deploy' });
    user.addEventListener('input', () => { d.opts.kioskUser = user.value; updatePreview(); });
    main.append(
      el('h2', { text: 'Deploy' }),
      el('p', { class: 'sub', text: 'Installing a launcher on a kiosk is done by the PowerShell deploy scripts, from the Kiosk Fleet folder on a Windows PC with admin rights on the kiosks. Pick a launcher, kiosks and options here, then copy the command and run it there. Write a new kiosk\'s config first (Add a kiosk...): that part this server does itself.' }),
      el('div', { class: 'deploy', id: 'dform' },
        el('div', null,
          el('h3', { text: '1. WHAT TO INSTALL' }), prodSeg, el('p', { class: 'hint', id: 'dprodnote' }),
          el('h3', { id: 'dtargettitle' }),
          el('div', { class: 'toolbar' }, filter,
            el('button', { class: 'btn small', type: 'button', text: 'All shown', onclick: () => { for (const r of visibleTargets()) d.ticks.add(r.host); renderDeployTargets(); updatePreview(); } }),
            el('button', { class: 'btn small', type: 'button', text: 'None', onclick: () => { d.ticks.clear(); renderDeployTargets(); updatePreview(); } }),
            el('button', { class: 'btn small', type: 'button', text: 'Add a kiosk...', onclick: addHostDialog })),
          el('div', { id: 'dtargets' })),
        el('div', null,
          el('h3', { text: '3. MODE' }), modeSeg,
          el('h3', { text: '4. OPTIONS' }),
          el('div', { class: 'card opts' },
            opt('restart', 'Restart each kiosk and wait for it', 'o_restart'),
            el('div', { class: 'inline' }, num('warnSeconds', 'Countdown on screen (s)', 'o_warn'), num('verifyMinutes', 'Wait for it to come back (min)', 'o_verify')),
            opt('force', 'Copy the files even if they are there', 'o_force'),
            opt('updateConfig', 'Rewrite the kiosk config from the old launcher', 'o_update'),
            opt('keepLegacy', 'Leave the old launcher in place', 'o_legacy'),
            opt('keepWatchdog', 'Leave the MWST watchdog in place', 'o_keepwd'),
            opt('registerTask', 'Register the launcher task', 'o_task'),
            opt('dryRun', 'Dry run: show what would happen, change nothing (-WhatIf)', 'o_dry'),
            el('label', { id: 'o_user' }, el('span', { class: 'lbl', text: 'Windows account the kiosk logs on as' }), user,
              el('span', { class: 'hint', text: 'Needed for a new kiosk whose account is not named after it (-KioskUser).' }))),
          el('h3', { text: '5. THE COMMAND' }),
          el('pre', { class: 'cmd', id: 'dpreview' }),
          el('p', { class: 'hint', id: 'dnote' }),
          el('div', { class: 'btnrow' },
            el('button', { class: 'btn primary', type: 'button', id: 'dcopy', text: 'Copy the command', onclick: () => d.preview && copyText(d.preview) }),
            el('span', { class: 'hint', text: 'Paste it into PowerShell in the Kiosk Fleet folder.' })))));
  }
  renderDeployForm();
  if (dataChanged) renderDeployTargets();
  updatePreview();
}

function renderDeployForm() {
  const d = S.deploy;
  const isWd = d.product === 'WATCHDOG';
  if (isWd) d.rollback = false;
  const info = productInfo(d.product);
  setKids($('#dprod'), ...(S.products.length ? S.products : [{ id: 'NG', name: 'Mach2 Launcher NG' }, { id: 'PBI', name: 'PBI Launcher' }, { id: 'WEB', name: 'Web Launcher' }, { id: 'WATCHDOG', name: 'MWST watchdog' }]).map((p) =>
    el('button', { type: 'button', class: 'btn' + (p.id === d.product ? ' on' : ''), role: 'radio', 'aria-checked': String(p.id === d.product), text: p.name,
      onclick: () => { d.product = p.id; renderDeployForm(); renderDeployTargets(); updatePreview(); } })));
  $('#dprodnote').textContent = info.note || '';
  $('#dtargettitle').textContent = '2. KIOSKS' + (info.tab === '*' ? '  (all)' : `  (${info.tab})`);
  setKids($('#dmode'), 
    el('button', { type: 'button', class: 'btn' + (!d.rollback ? ' on' : ''), role: 'radio', 'aria-checked': String(!d.rollback), text: 'Install / update', onclick: () => { d.rollback = false; renderDeployForm(); updatePreview(); } }),
    el('button', { type: 'button', class: 'btn' + (d.rollback ? ' on' : ''), role: 'radio', 'aria-checked': String(d.rollback), text: 'Roll back', disabled: isWd, title: isWd ? 'The old watchdog has no roll back' : null, onclick: () => { d.rollback = true; renderDeployForm(); updatePreview(); } }));
  $('#o_update').classList.toggle('hidden', isWd || d.product === 'WEB');
  $('#o_legacy').classList.toggle('hidden', isWd);
  $('#o_keepwd').classList.toggle('hidden', d.product !== 'NG');
  $('#o_task').classList.toggle('hidden', !isWd);
  $('#o_verify').querySelector('input').disabled = isWd;
  $('#o_user').querySelector('input').disabled = isWd;
}

function visibleTargets() {
  const t = S.deploy.filter.trim().toLowerCase();
  return deployTargets().filter((r) => !t || [r.host, r.location, r.status, r.note].some((x) => x && x.toLowerCase().includes(t)));
}

function renderDeployTargets() {
  const box = $('#dtargets');
  if (!box) return;
  const d = S.deploy;
  const all = deployTargets();
  // Ticks stay with the kiosks that are still in the list.
  const hosts = new Set(all.map((r) => r.host));
  for (const h of [...d.ticks]) if (!hosts.has(h)) d.ticks.delete(h);
  const rows = visibleTargets();
  if (!all.length) { setKids(box, el('div', { class: 'card empty', text: 'No kiosks for this in the data.' })); return; }
  setKids(box, el('div', { class: 'tablewrap' }, el('table', null,
    el('thead', null, el('tr', null, ['', 'KIOSK', 'LOCATION', 'STATUS', 'RUNS NOW'].map((h) => el('th', { class: 'nosort', text: h })))),
    el('tbody', null, rows.map((r) => {
      const c = el('input', { type: 'checkbox', checked: d.ticks.has(r.host), 'aria-label': 'Deploy to ' + r.host });
      c.addEventListener('click', (e) => e.stopPropagation());
      c.addEventListener('change', () => { if (c.checked) d.ticks.add(r.host); else d.ticks.delete(r.host); updatePreview(); });
      const tr = el('tr', null, el('td', null, c), el('td', { class: 'host', text: r.host }), el('td', { text: r.location }),
        el('td', null, pill(r.status, r.sev)), el('td', { class: 'dim', text: r.note, title: r.note }));
      tr.addEventListener('click', () => { c.checked = !c.checked; c.dispatchEvent(new Event('change')); });
      return tr;
    })))));
}

function addHostDialog() {
  const d = S.deploy;
  const isWd = d.product === 'WATCHDOG';
  openModal({
    title: 'Add a kiosk', sub: `It joins the list for ${productInfo(d.product).name} even though the last scan did not see it.`,
    body: 'For a kiosk that is new, was switched off, or is not in the master list yet. The deploy checks it is really there.',
    fields: [
      { key: 'host', label: 'Kiosk name', hint: 'The name the kiosk answers to on the network.', max: 63 },
      { key: 'setup', label: 'Settings', kind: 'bool', value: isWd ? '0' : '1', hint: 'fill in its URL, account and password next' }
    ],
    okText: 'Add it',
    onOk: async (v, m) => {
      const name = (v.host || '').trim().replace(/^\\+|\\+$/g, '');
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(name)) { m.setNote('That is not a kiosk name.', 'CRITICAL'); return true; }
      if (!deployTargets().some((r) => r.host.toLowerCase() === name.toLowerCase())) d.extra[d.product].push(name);
      const real = deployTargets().find((r) => r.host.toLowerCase() === name.toLowerCase());
      d.ticks.add(real ? real.host : name);
      renderDeployTargets();
      updatePreview();
      if (v.setup === '1' && !isWd) { configEditor(real ? real.host : name, ['PBI', 'WEB'].includes(d.product) ? d.product : 'NG', ''); return true; }
      toast(`${name} is in the list.`, 'OK');
    }
  });
}

// ---------------------------------------------------------------------------
// Activity
// ---------------------------------------------------------------------------
async function loadReports() {
  try { S.reports = (await api('GET', '/api/reports')).reports; } catch (e) { S.reports = []; }
  if (S.view === 'Activity') renderReports();
}

async function pollRun() {
  clearTimeout(S.run.timer);
  if (S.view !== 'Activity' || !S.me) return;
  try {
    const r = await api('GET', '/api/run?from=' + S.run.from);
    if (r.text) {
      S.run.text += r.text;
      if (S.run.text.length > 1500000) S.run.text = S.run.text.slice(-1000000);
      const pre = $('#console');
      if (pre) {
        const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
        pre.textContent = S.run.text || 'Nothing has run since the server started.';
        if (atEnd) pre.scrollTop = pre.scrollHeight;
      }
    }
    S.run.from = r.next;
    if (S.run.wasRunning && !r.running) loadReports();
    S.run.wasRunning = r.running;
  } catch (e) { /* the next tick tries again */ }
  S.run.timer = setTimeout(pollRun, S.live && S.live.run ? 1000 : 3000);
}

function renderActivity(main) {
  if (!$('#console', main)) {
    main.append(
      el('h2', { text: 'Activity' }),
      el('p', { class: 'sub', text: 'The output of a scan as it happens, whoever started it. Every run\'s output is also kept on the server (logs/run in the data folder) for two weeks.' }),
      el('div', { class: 'toolbar', id: 'atool' }),
      el('pre', { class: 'console', id: 'console', tabindex: '0', 'aria-label': 'Output', text: S.run.text || 'Nothing has run since the server started.' }),
      el('h3', { text: 'REPORTS' }),
      el('div', { id: 'reports' }));
    renderReports();
    const pre = $('#console', main);
    pre.scrollTop = pre.scrollHeight;
  }
  const run = S.live.run, last = S.live.lastRun;
  const state = run ? `${run.title} - running for ${run.elapsed} (${run.who})`
    : last ? `${last.Title} - finished with code ${last.Code} after ${last.Seconds}s at ${last.Finished}` : 'Nothing running.';
  setKids($('#atool', main), 
    el('span', { class: run ? 'sev-UNKNOWN' : (last && last.Code !== 0 ? 'sev-WARNING' : 'dim'), text: state }),
    el('span', { style: { flex: '1' } }),
    can('stoprun') ? el('button', { class: 'btn small danger', type: 'button', text: 'Stop it', disabled: !run, onclick: stopRun }) : null,
    el('button', { class: 'btn small', type: 'button', text: 'Clear', onclick: () => { S.run.text = ''; $('#console').textContent = ''; } }),
    el('button', { class: 'btn small', type: 'button', text: 'Save output', onclick: saveOutput }));
}

function saveOutput() {
  const blob = new Blob([S.run.text], { type: 'text/plain' });
  const a = el('a', { href: URL.createObjectURL(blob), download: 'kiosk-fleet-output.txt' });
  document.body.append(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

function renderReports() {
  const box = $('#reports');
  if (!box) return;
  if (!S.reports.length) { setKids(box, el('div', { class: 'card empty', text: 'No reports yet.' })); return; }
  setKids(box, el('div', { class: 'tablewrap' }, el('table', null,
    el('thead', null, el('tr', null, ['WHEN', 'WHAT', 'FILE'].map((h) => el('th', { class: 'nosort', text: h })))),
    el('tbody', null, S.reports.map((r) => el('tr', null,
      el('td', { text: r.when }), el('td', { text: r.kind }),
      el('td', null, el('a', { href: '/api/reports/' + encodeURIComponent(r.name), download: r.name, text: r.name }))))))));
}

function stopRun() {
  openModal({
    title: 'Stop it?', danger: true, okText: 'Stop it',
    body: `${S.live.run ? S.live.run.title : 'It'} is still running. Stopping it leaves whatever it was in the middle of half done; a kiosk mid-install would need the deploy running again.`,
    onOk: async () => {
      try { await api('POST', '/api/run/stop'); toast('Stopped.', 'WARNING'); refreshSoon(); }
      catch (e) { toast(e.message, 'CRITICAL'); }
    }
  });
}

// ---------------------------------------------------------------------------
// Audit
// ---------------------------------------------------------------------------
async function loadAudit() {
  try { S.audit = (await api('GET', '/api/audit?q=' + encodeURIComponent(S.auditFilter))).entries; } catch (e) { S.audit = []; toast(e.message, 'WARNING'); }
  if (S.view === 'Audit') renderAudit($('#main'), true);
}

function renderAudit(main, force) {
  if (!$('#atool2', main)) {
    const search = el('input', { type: 'search', value: S.auditFilter, placeholder: 'Search: user, action, kiosk, result, detail', 'aria-label': 'Search the audit log' });
    let t = null;
    search.addEventListener('input', () => { S.auditFilter = search.value; clearTimeout(t); t = setTimeout(loadAudit, 300); });
    setKids(main,
      el('h2', { text: 'Audit log' }),
      el('p', { class: 'sub', text: 'Who did what, newest first: every sign-in, every action on a kiosk, every scan, every change to an account. The newest 400 that match are shown; the whole log downloads as CSV.' }),
      el('div', { class: 'toolbar', id: 'atool2' }, search,
        el('button', { class: 'btn small', type: 'button', text: 'Refresh', onclick: loadAudit }),
        el('a', { class: 'btn small', href: '/api/audit.csv', download: 'kiosk-fleet-audit.csv', text: 'Download all (CSV)' })),
      el('div', { id: 'audit' }));
    force = true;
  }
  if (!force) return;
  const res = (r) => (r === 'ok' || r === 'started' ? 'sev-OK' : r === 'failed' || r === 'refused' ? 'sev-CRITICAL' : r === 'waiting' ? 'sev-WARNING' : 'dim');
  setKids($('#audit', main), S.audit.length ? el('div', { class: 'tablewrap' }, el('table', null,
    el('thead', null, el('tr', null, ['TIME', 'USER', 'ROLE', 'FROM', 'ACTION', 'TARGET', 'RESULT', 'DETAIL'].map((h) => el('th', { class: 'nosort', text: h })))),
    el('tbody', null, S.audit.map((a) => el('tr', null,
      el('td', { text: (a.Time || '').replace('T', ' ') }), el('td', { text: a.User }), el('td', { text: a.Role }),
      el('td', { class: 'dim', text: a.Ip }), el('td', { text: a.Action }), el('td', { text: a.Target, title: a.Target }),
      el('td', { class: res(a.Result), text: a.Result }), el('td', { class: 'dim', text: a.Detail, title: a.Detail }))))))
    : el('div', { class: 'card empty', text: S.auditFilter ? 'Nothing matches.' : 'Nothing yet.' }));
}

// ---------------------------------------------------------------------------
// Your own password
// ---------------------------------------------------------------------------
function changePasswordDialog() {
  openModal({
    title: 'Change your password', sub: S.me.user,
    fields: [{ key: 'current', label: 'Current password', kind: 'secret' }, { key: 'password', label: 'New password', kind: 'password' }],
    note: 'At least 12 characters, with three of: lower case, upper case, digits, symbols - or 20 characters or more. Your other sessions are signed out.',
    okText: 'Change it',
    onOk: async (v, m) => {
      if (v.password !== v['password.again']) { m.setNote('The two new passwords did not match.', 'CRITICAL'); return true; }
      m.busy(true);
      try {
        await api('POST', '/api/me/password', { current: v.current, password: v.password, password2: v['password.again'] });
        m.clearSecrets();
        m.finish('Changed.', 'OK');
      } catch (e) { m.busy(false); m.setNote(e.message, 'CRITICAL'); }
      return true;
    }
  });
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------
async function loadUsers() {
  try { S.users = (await api('GET', '/api/users')).users; } catch (e) { S.users = []; toast(e.message, 'WARNING'); }
  if (S.view === 'Users') renderUsers($('#main'), true);
}

function renderUsers(main, force) {
  if (!can('users')) { setKids(main, el('div', { class: 'card empty', text: 'Accounts are for admins.' })); return; }
  if ($('#users', main) && !force) return;
  const rows = S.users.map((u) => el('tr', { class: u.disabled ? 'dim' : '' },
    el('td', { class: 'host', text: u.name }),
    el('td', null, el('span', { class: 'role ' + u.role, text: u.role })),
    el('td', { class: u.disabled || u.mustChange ? 'sev-WARNING' : 'sev-OK', text: u.disabled ? 'disabled' : (u.mustChange ? 'must change password' : 'active') }),
    el('td', { text: (u.lastLogin || 'never').replace('T', ' ') }),
    el('td', { text: u.sessions ? String(u.sessions) : '' }),
    el('td', { text: (u.created || '').replace('T', ' ').slice(0, 16) }),
    el('td', null, el('button', { class: 'btn small', type: 'button', text: 'Change...', onclick: () => userDialog(u) }))));
  setKids(main,
    el('h2', { text: 'Users' }),
    el('p', { class: 'sub', text: 'Everyone signs in with an account of their own. Operators see everything and can do what cannot break a kiosk; admins can do everything, including this page.' }),
    el('div', { class: 'toolbar' }, el('button', { class: 'btn small primary', type: 'button', text: 'Add an account...', onclick: addUserDialog }),
      el('button', { class: 'btn small', type: 'button', text: 'Refresh', onclick: loadUsers })),
    el('div', { id: 'users' }, S.users.length ? el('div', { class: 'tablewrap' }, el('table', null,
      el('thead', null, el('tr', null, ['ACCOUNT', 'ROLE', 'STATE', 'LAST SIGN-IN', 'SESSIONS', 'CREATED', ''].map((h) => el('th', { class: 'nosort', text: h })))),
      el('tbody', null, rows))) : el('div', { class: 'card empty', text: 'No accounts.' })));
}

const ROLE_OPTIONS = [{ value: 'operator', text: 'Operator - sees everything; scan, read live, screenshot, reload, message, log' }, { value: 'admin', text: 'Admin - everything' }];

function addUserDialog() {
  openModal({
    title: 'Add an account',
    fields: [
      { key: 'name', label: 'Account name', hint: 'Letters, digits, dots, dashes, underscores or @ - an e-mail address works.', max: 64 },
      { key: 'role', label: 'Role', kind: 'choice', value: 'operator', options: ROLE_OPTIONS },
      { key: 'password', label: 'Password', kind: 'password' },
      { key: 'mustChange', label: 'At first sign-in', kind: 'bool', value: '1', hint: 'they choose a password of their own' }
    ],
    note: 'At least 12 characters, with three of: lower case, upper case, digits, symbols - or 20 characters or more.',
    okText: 'Add it',
    onOk: async (v, m) => {
      if (v.password !== v['password.again']) { m.setNote('The two passwords did not match.', 'CRITICAL'); return true; }
      m.busy(true);
      try {
        await api('POST', '/api/users', { name: v.name, role: v.role, password: v.password, password2: v['password.again'], mustChange: v.mustChange === '1' });
        toast(`${v.name} added.`, 'OK');
        loadUsers();
      } catch (e) { m.busy(false); m.setNote(e.message, 'CRITICAL'); return true; }
    }
  });
}

function userDialog(u) {
  const self = u.name.toLowerCase() === S.me.user.toLowerCase();
  const m = openModal({
    title: u.name, sub: `${u.role}${u.disabled ? ', disabled' : ''}. Last sign-in: ${(u.lastLogin || 'never').replace('T', ' ')}.`,
    fields: [
      { key: 'role', label: 'Role', kind: 'choice', value: u.role, options: ROLE_OPTIONS },
      { key: 'disabled', label: 'Disabled', kind: 'bool', value: u.disabled ? '1' : '0', hint: 'cannot sign in; signed out at once' },
      { key: 'h1', label: 'NEW PASSWORD (leave empty to keep it)', kind: 'note' },
      { key: 'password', label: 'New password', kind: 'password' },
      { key: 'mustChange', label: 'At next sign-in', kind: 'bool', value: self ? '0' : '1', hint: 'they choose a password of their own' }
    ],
    extra: el('div', { class: 'btnrow' },
      el('button', { class: 'btn small', type: 'button', text: 'Sign out everywhere', onclick: async () => {
        try { await api('POST', '/api/users/' + encodeURIComponent(u.name), { signOut: true }); toast(`${u.name} is signed out.`, 'OK'); loadUsers(); }
        catch (e) { toast(e.message, 'CRITICAL'); }
      } }),
      self ? null : el('button', { class: 'btn small danger', type: 'button', text: 'Remove the account...', onclick: () => removeUserDialog(u) })),
    okText: 'Save',
    onOk: async (v, mm) => {
      const body = {};
      if (v.role !== u.role) body.role = v.role;
      if ((v.disabled === '1') !== u.disabled) body.disabled = v.disabled === '1';
      if (v.password || v['password.again']) {
        if (v.password !== v['password.again']) { mm.setNote('The two passwords did not match.', 'CRITICAL'); return true; }
        Object.assign(body, { password: v.password, password2: v['password.again'], mustChange: v.mustChange === '1' });
      }
      if (!Object.keys(body).length) return;
      mm.busy(true);
      try {
        const r = await api('POST', '/api/users/' + encodeURIComponent(u.name), body);
        toast(`${u.name}: ${r.changed.join(', ') || 'saved'}.`, 'OK');
        loadUsers();
      } catch (e) { mm.busy(false); mm.setNote(e.message, 'CRITICAL'); return true; }
    }
  });
  return m;
}

function removeUserDialog(u) {
  openModal({
    title: `Remove ${u.name}?`, danger: true, okText: 'Remove it',
    body: 'The account goes, and with it every session it has open. What it did stays in the audit log. To stop someone signing in for a while, disable the account instead.',
    onOk: async (v, m) => {
      try { await api('DELETE', '/api/users/' + encodeURIComponent(u.name)); toast(`${u.name} removed.`, 'OK'); loadUsers(); }
      catch (e) { m.setNote(e.message, 'CRITICAL'); return true; }
    }
  });
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------
async function loadSettings() {
  try { S.settings = await api('GET', '/api/settings'); } catch (e) { S.settings = null; toast(e.message, 'WARNING'); }
  if (S.view === 'Settings') renderSettings($('#main'), true);
}

function renderSettings(main, force) {
  if (!can('settings')) { setKids(main, el('div', { class: 'card empty', text: 'Settings are for admins.' })); return; }
  if ($('#settings', main) && !force) return;
  const c = S.settings;
  if (!c) { setKids(main, el('h2', { text: 'Settings' }), el('div', { class: 'card empty', id: 'settings', text: 'Reading the settings...' })); return; }
  const kv = (k, v, cls) => [el('div', { class: 'k', text: k }), el('div', { class: 'v' + (cls ? ' ' + cls : ''), text: v })];
  const L = c.kioskList;
  const file = el('input', { type: 'file', accept: '.xlsx,.csv,.txt', 'aria-label': 'Kiosk list file' });
  const upNote = el('div', { class: 'note', role: 'status' });
  const upload = el('button', { class: 'btn small primary', type: 'button', text: 'Upload', disabled: c.kioskListFixed, onclick: async () => {
    if (!file.files.length) { upNote.textContent = 'Pick a file first.'; upNote.className = 'note sev-WARNING'; return; }
    const fd = new FormData();
    fd.append('file', file.files[0]);
    upload.disabled = true;
    upNote.textContent = 'uploading ...';
    upNote.className = 'note';
    try {
      const r = await fetch('/api/settings/kiosk-list', { method: 'POST', body: fd, credentials: 'same-origin', headers: { 'X-Fleet-Csrf': S.me.csrf } });
      const d = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(d.error || ('HTTP ' + r.status));
      toast(`Kiosk list saved: ${d.kiosks} kiosks to scan.`, 'OK');
      loadSettings();
      refreshSoon();
    } catch (e) { upNote.textContent = e.message; upNote.className = 'note sev-CRITICAL'; upload.disabled = false; }
  } });
  const listCard = el('div', { class: 'card' },
    L.exists ? el('div', { class: 'kv' },
      kv('File', L.path, 'dim'), kv('Changed', L.modified || ''),
      L.error ? kv('Problem', L.error, 'sev-CRITICAL') : [kv('Rows', String(L.rows)), kv('To scan', `${L.included} (${L.watchdog} with the watchdog)`),
        kv('Not scanned', `${L.inactive} not active, ${L.notFlagged} not flagged`)])
      : el('p', { class: 'sev-WARNING', text: 'No kiosk list yet.' }),
    el('p', { class: 'hint', text: 'An .xlsx (the master kiosk list: NAME or HOST, TYPE, HAS MWST, ACTIVE, LOCATION, RESTART GROUP columns), a .csv with Host, Location, Type, HasMwst, Active, RestartGroup, or a .txt with one kiosk name per line.' }),
    c.kioskListFixed ? el('p', { class: 'hint', text: 'This server reads the list named by KFW_KIOSK_LIST; change it there.' })
      : el('div', { class: 'btnrow' }, file, upload, L.exists ? el('a', { class: 'btn small', href: '/api/settings/kiosk-list', text: 'Download the current one' }) : null),
    upNote);
  const k = c.kiosks;
  const kioskCard = el('div', { class: 'card' }, el('div', { class: 'kv' },
    kv('Kiosk drive', k.rootTemplate.replace('{0}', '<kiosk>'), 'dim'),
    kv('Reached over', k.smb ? `SMB, ${k.auth}` : 'a local folder (test or demo kiosks)'),
    k.smb ? kv('Credential', k.credential ? k.user : 'none - set KIOSK_ADMIN_USER and KIOSK_ADMIN_PASSWORD', k.credential ? '' : 'sev-CRITICAL') : null),
    el('div', { class: 'btnrow', style: { marginTop: '10px' } }, el('button', { class: 'btn small', type: 'button', text: 'Test a kiosk...', onclick: testKioskDialog })));
  const col = c.collector, ses = c.sessions, d = c.data;
  const other = el('div', { class: 'card' }, el('div', { class: 'kv' },
    kv('Data folder', d.dir, 'dim'), kv('Events file', d.csv, 'dim'), kv('Also published to', d.published || '-', 'dim'),
    kv('Auto-scan', `${col.autoscanDefault ? 'on at start' : 'off at start'}, every ${col.minutes} min`),
    kv('Kiosks at a time', String(col.parallel)), kv('Give up on a kiosk after', col.hostTimeout + ' s'),
    kv('Keep events for', col.retentionDays + ' days'), kv('Trust watchdog data from', 'v' + col.trustedFrom),
    kv('Sessions', `signed out after ${ses.idleMinutes} min idle, ${ses.hours} h at most`),
    kv('Secure cookies', ses.secureCookies + (ses.trustProxy ? ', behind a trusted proxy' : '')),
    kv('Version', c.version)));
  setKids(main,
    el('h2', { text: 'Settings' }),
    el('p', { class: 'sub', text: 'What this server scans and how it reaches the kiosks. Everything but the kiosk list is set by environment variables when the container starts (see the README).' }),
    el('div', { id: 'settings', class: 'ov' },
      el('div', null, el('h3', { text: 'KIOSK LIST' }), listCard),
      el('div', null, el('h3', { text: 'REACHING THE KIOSKS' }), kioskCard, el('h3', { text: 'THIS SERVER' }), other)));
}

function testKioskDialog() {
  openModal({
    title: 'Test a kiosk', sub: 'Can this server reach it, and open its admin share?',
    fields: [{ key: 'host', label: 'Kiosk name', max: 63 }],
    okText: 'Test it', withLog: true,
    onOk: async (v, m) => {
      const name = (v.host || '').trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(name)) { m.setNote('That is not a kiosk name.', 'CRITICAL'); return true; }
      m.busy(true);
      try {
        const r = await api('POST', `/api/kiosks/${encodeURIComponent(name)}/test`, {});
        const j = await waitJob(r.job, (l) => m.log(l));
        if (j.result && j.result.lines) for (const l of j.result.lines) m.log(`${l.Label}: ${l.Value}`);
        m.busy(false);
        m.setNote(j.detail, j.ok ? 'OK' : 'CRITICAL');
      } catch (e) { m.busy(false); m.setNote(e.message, 'CRITICAL'); }
      return true;
    }
  });
}

start();
