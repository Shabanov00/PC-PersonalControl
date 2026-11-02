'use strict';
// PC-PersonalControl Cloud: API для агентов, Telegram-бот и сайт. Без зависимостей, Node 18+.
const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const C = {
  port: Number(process.env.PORT || 8080),
  token: process.env.BOT_TOKEN || '',
  botName: (process.env.BOT_USERNAME || '').replace(/^@/, ''),
  adminKey: process.env.ADMIN_KEY || '',
  publicUrl: (process.env.PUBLIC_URL || '').replace(/\/+$/, ''),
  dataDir: path.resolve(process.env.DATA_DIR || path.join(__dirname, 'data')),
  webDir: path.resolve(process.env.WEB_DIR || path.join(__dirname, 'web')),
  tgApi: process.env.TELEGRAM_API || 'https://api.telegram.org',
};
if (require.main === module) {
  if (!C.token || !C.botName || !C.publicUrl || C.adminKey.length < 24) {
    console.error('Нужны переменные: BOT_TOKEN, BOT_USERNAME, PUBLIC_URL (https://...), ADMIN_KEY (>=24 символов).');
    process.exit(1);
  }
}
const SEMVER = /^\d{1,4}\.\d{1,4}\.\d{1,4}$/;
const ACTIONS = new Set(['sleep', 'lock', 'shutdown', 'restart', 'timer', 'cancel', 'wake']);
const CMD_TTL = 120e3, ONLINE_MS = 45e3, PAIR_TTL = 15 * 60e3;
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

// ---------- хранилище ----------
fs.mkdirSync(path.join(C.dataDir, 'releases'), { recursive: true });
const dbPath = path.join(C.dataDir, 'db.json');
let db = { devices: {}, releases: [], tgOffset: 0 };
try { db = Object.assign(db, JSON.parse(fs.readFileSync(dbPath, 'utf8'))); } catch {}
let saveTimer = null;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    fs.writeFileSync(dbPath + '.tmp', JSON.stringify(db));
    fs.renameSync(dbPath + '.tmp', dbPath);
  }, 300);
}
const pairings = new Map();   // code -> {deviceId, exp}
const snapshots = new Map();  // deviceId -> {at, data}
const commands = new Map();   // commandId -> {deviceId, action, arg, exp, status, message}
const waiters = new Map();    // deviceId -> {res, timer}
const viewed = new Map();     // deviceId -> когда панель последний раз запрашивала данные
const hits = new Map();       // ip -> [timestamps]

const sha256 = (b) => crypto.createHash('sha256').update(b).digest('hex');
const rnd = (n) => crypto.randomBytes(n).toString('hex');
const safeEq = (a, b) => { const x = Buffer.from(String(a)), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); };
const newCode = () => Array.from(crypto.randomBytes(8), (b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join('');
const cmpVer = (a, b) => { const x = a.split('.').map(Number), y = b.split('.').map(Number); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0; };
const latest = () => db.releases.slice().sort((a, b) => cmpVer(b.version, a.version))[0] || null;
function limited(ip, max, windowMs) {
  const now = Date.now(), arr = (hits.get(ip) || []).filter((t) => now - t < windowMs);
  arr.push(now); hits.set(ip, arr); return arr.length > max;
}

// ---------- Telegram ----------
async function tg(method, body) {
  const r = await fetch(`${C.tgApi}/bot${C.token}/${method}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body || {}),
    signal: AbortSignal.timeout(45e3),
  });
  const j = await r.json();
  if (!j.ok) throw new Error(`Telegram ${method}: ${j.description}`);
  return j.result;
}
const panelButton = () => ({ inline_keyboard: [[{ text: '✨ Открыть панель', web_app: { url: C.publicUrl + '/app.html' } }]] });
const say = (chat, text, extra) => tg('sendMessage', Object.assign({ chat_id: chat, text }, extra || {})).catch((e) => log('tg send:', e.message));
const log = (...a) => console.log(new Date().toISOString(), ...a.map((x) => String(x).split(C.token).join('[token]')));

function verifyInitData(raw) {
  try {
    const p = new URLSearchParams(String(raw || ''));
    const hash = p.get('hash'); p.delete('hash');
    if (!hash) return null;
    const str = [...p.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1)).map(([k, v]) => `${k}=${v}`).join('\n');
    const secret = crypto.createHmac('sha256', 'WebAppData').update(C.token).digest();
    const calc = crypto.createHmac('sha256', secret).update(str).digest('hex');
    if (!safeEq(calc, hash)) return null;
    if (Date.now() / 1000 - Number(p.get('auth_date')) > 86400) return null;
    const user = JSON.parse(p.get('user'));
    return Number.isSafeInteger(user.id) ? String(user.id) : null;
  } catch { return null; }
}

function describe(dev, snap) {
  if (!snap) return `🖥 ${dev.name}\nДанных пока нет.`;
  const d = snap.data, t = (k) => d.temps.filter((x) => x.kind === k).map((x) => Math.round(x.value));
  const cpu = t('cpu')[0], gpu = t('gpu')[0];
  const fans = d.fans.filter((f) => f.rpm != null).map((f) => `${f.name}: ${Math.round(f.rpm)} об/мин`);
  return [`🖥 ${dev.name}`, cpu != null ? `🌡 CPU: ${cpu}°C` : '', gpu != null ? `🌡 GPU: ${gpu}°C` : '',
    ...fans.slice(0, 8).map((x) => '🌀 ' + x)].filter(Boolean).join('\n');
}
const myDevices = (uid) => Object.entries(db.devices).filter(([, d]) => d.ownerId === uid);

async function onMessage(m) {
  if (!m.text || m.chat.type !== 'private') return;
  const uid = String(m.from.id), chat = m.chat.id, text = m.text.trim();
  const start = /^\/start(?:@\w+)?(?:\s+([A-Z2-9]{8}))?$/i.exec(text);
  if (start && start[1]) {
    const code = start[1].toUpperCase(), p = pairings.get(code);
    if (!p || p.exp < Date.now()) return say(chat, '⚠️ Код не найден или устарел. Перезапустите PC-PersonalControl на ПК — он покажет новую ссылку.');
    const dev = db.devices[p.deviceId];
    if (!dev || dev.ownerId) return say(chat, '⚠️ Это устройство уже привязано.');
    dev.ownerId = uid; dev.linkedAt = Date.now(); pairings.delete(code); save();
    return say(chat, `✅ «${dev.name}» привязан к вашему аккаунту. Температуры, вентиляторы и управление — в панели.`, { reply_markup: panelButton() });
  }
  if (start || /^\/(menu|help)(@\w+)?$/i.test(text))
    return say(chat, 'PC-PersonalControl на связи. Ожидаю Ваши команды.\n\n/status — температуры и вентиляторы\n/unlink — отвязать все ваши ПК\n\nУстановите приложение на ПК: ' + C.publicUrl, { reply_markup: panelButton() });
  if (/^\/status(@\w+)?$/i.test(text)) {
    const list = myDevices(uid);
    return say(chat, list.length ? list.map(([id, d]) => describe(d, snapshots.get(id))).join('\n\n') : 'Нет привязанных ПК. Установите PC-PersonalControl: ' + C.publicUrl);
  }
  if (/^\/unlink(@\w+)?$/i.test(text)) {
    const list = myDevices(uid);
    for (const [id] of list) { enqueue(id, 'unlink'); setTimeout(() => { delete db.devices[id]; snapshots.delete(id); save(); }, 5000); }
    return say(chat, list.length ? `Отвязано устройств: ${list.length}.` : 'Привязанных ПК нет.');
  }
}
async function botLoop() {
  try { await tg('setChatMenuButton', { menu_button: { type: 'web_app', text: 'Панель', web_app: { url: C.publicUrl + '/app.html' } } }); } catch (e) { log(e.message); }
  try { await tg('setMyCommands', { commands: [{ command: 'status', description: 'Температуры и вентиляторы' }, { command: 'menu', description: 'Открыть панель' }, { command: 'unlink', description: 'Отвязать мои ПК' }] }); } catch {}
  for (;;) {
    try {
      const ups = await tg('getUpdates', { offset: db.tgOffset, timeout: 30, allowed_updates: ['message'] });
      for (const u of ups) { db.tgOffset = u.update_id + 1; if (u.message) await onMessage(u.message).catch((e) => log('msg:', e.message)); }
      if (ups.length) save();
    } catch (e) { log('getUpdates:', e.message); await new Promise((r) => setTimeout(r, 4000)); }
  }
}

// ---------- команды ----------
function enqueue(deviceId, action, arg) {
  const c = { id: rnd(8), deviceId, action, arg, exp: Date.now() + CMD_TTL, status: 'queued', message: '' };
  commands.set(c.id, c);
  const w = waiters.get(deviceId);
  if (w) { clearTimeout(w.timer); waiters.delete(deviceId); reply(w.res, 200, { commands: pending(deviceId) }); }
  return c;
}
const pending = (deviceId) => [...commands.values()].filter((c) => c.deviceId === deviceId && c.status === 'queued' && c.exp > Date.now())
  .map((c) => { c.status = 'sent'; return { id: c.id, action: c.action, arg: c.arg }; });
setInterval(() => {
  const now = Date.now();
  for (const [k, c] of commands) if (c.exp + 600e3 < now) commands.delete(k);
  for (const [k, p] of pairings) if (p.exp < now) pairings.delete(k);
  for (const [id, d] of Object.entries(db.devices)) if (!d.ownerId && now - d.createdAt > 864e5) { delete db.devices[id]; save(); }
  for (const [k, v] of hits) if (!v.length || now - v[v.length - 1] > 36e5) hits.delete(k);
}, 60e3).unref();

// ---------- HTTP ----------
function reply(res, code, obj, headers) {
  if (res.writableEnded) return;
  res.writeHead(code, Object.assign({ 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }, headers));
  res.end(JSON.stringify(obj));
}
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => { size += c.length; if (size > limit) { reject(Object.assign(new Error('too_large'), { code: 413 })); req.destroy(); } else chunks.push(c); });
    req.on('end', () => { try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); } catch { reject(Object.assign(new Error('bad_json'), { code: 400 })); } });
    req.on('error', reject);
  });
}
const str = (v, n) => String(v == null ? '' : v).replace(/[\u0000-\u001f<>]/g, '').slice(0, n);
const num = (v) => (Number.isFinite(Number(v)) && v !== null && v !== '' ? Math.round(Number(v) * 10) / 10 : null);
function clean(s) {
  s = s || {}; const sp = s.specs || {};
  const arr = (a, n, f) => (Array.isArray(a) ? a.slice(0, n).map(f) : []);
  return {
    host: str(s.host, 60), agent: str(s.agent, 16), uptimeMin: num(s.uptimeMin),
    specs: {
      os: str(sp.os, 80), board: str(sp.board, 80), ramGB: num(sp.ramGB),
      cpu: { name: str(sp.cpu && sp.cpu.name, 100), cores: num(sp.cpu && sp.cpu.cores), threads: num(sp.cpu && sp.cpu.threads) },
      gpu: arr(sp.gpu, 4, (g) => ({ name: str(g.name, 100), vramMB: num(g.vramMB) })),
      disks: arr(sp.disks, 12, (d) => ({ name: str(d.name, 80), sizeGB: num(d.sizeGB) })),
    },
    temps: arr(s.temps, 48, (t) => ({ hw: str(t.hw, 80), name: str(t.name, 60), value: num(t.value), kind: ['cpu', 'gpu'].includes(t.kind) ? t.kind : 'other' })).filter((t) => t.value != null),
    fans: arr(s.fans, 24, (f) => ({ hw: str(f.hw, 80), name: str(f.name, 60), rpm: num(f.rpm), percent: num(f.percent) })),
    load: { cpu: num(s.load && s.load.cpu), gpu: num(s.load && s.load.gpu), ram: num(s.load && s.load.ram) },
  };
}
function deviceAuth(req) {
  const m = /^Bearer ([0-9a-f]{64})$/.exec(req.headers.authorization || '');
  if (!m) return null;
  const h = sha256(m[1]);
  for (const [id, d] of Object.entries(db.devices)) if (safeEq(d.keyHash, h)) return [id, d];
  return null;
}
function pairInfo(id) {
  for (const [c, p] of pairings) if (p.deviceId === id) pairings.delete(c);
  const code = newCode(); pairings.set(code, { deviceId: id, exp: Date.now() + PAIR_TTL });
  return { pairCode: code, pairUrl: `https://t.me/${C.botName}?start=${code}`, botUsername: C.botName };
}
function relInfo(r) {
  return r && { version: r.version, date: r.date, notes: r.notes, agent: r.agent, exe: r.exe };
}

async function api(req, res, url) {
  const route = req.method + ' ' + url.pathname, ip = req.socket.remoteAddress;
  // --- публичные ---
  if (route === 'GET /api/v1/info') return reply(res, 200, { botUsername: C.botName });
  if (route === 'GET /api/v1/update') return reply(res, 200, { release: relInfo(latest()) });
  if (route === 'GET /api/v1/releases') return reply(res, 200, { releases: db.releases.slice().sort((a, b) => cmpVer(b.version, a.version)).slice(0, 20).map(relInfo) });
  // --- администратор ---
  if (route === 'POST /api/v1/admin/release') {
    if (limited(ip, 20, 36e5) || !safeEq(req.headers['x-admin-key'] || '', C.adminKey)) return reply(res, 403, { error: 'forbidden' });
    const b = await readBody(req, 12e6);
    if (!SEMVER.test(b.version || '') || !b.agent_b64 || !b.agent_sig_b64) return reply(res, 400, { error: 'version, agent_b64, agent_sig_b64 обязательны' });
    if (db.releases.some((r) => r.version === b.version)) return reply(res, 409, { error: 'версия уже опубликована' });
    const agent = Buffer.from(b.agent_b64, 'base64');
    fs.writeFileSync(path.join(C.dataDir, 'releases', `agent-${b.version}.ps1`), agent);
    const rel = { version: b.version, date: new Date().toISOString(), notes: str(b.notes, 1500).replace(/[<>]/g, ''),
      agent: { url: `/dl/agent-${b.version}.ps1`, sha256: sha256(agent), signature: str(b.agent_sig_b64, 1000) }, exe: null };
    if (b.exe_b64) {
      const exe = Buffer.from(b.exe_b64, 'base64');
      fs.writeFileSync(path.join(C.dataDir, 'releases', `FanPilot-${b.version}.exe`), exe);
      rel.exe = { url: `/dl/FanPilot-${b.version}.exe`, sha256: sha256(exe), size: exe.length };
    }
    db.releases.push(rel); save();
    let sent = 0;
    if (b.notify !== false) {
      const owners = [...new Set(Object.values(db.devices).map((d) => d.ownerId).filter(Boolean))];
      for (const o of owners) { await say(o, `🆕 PC-PersonalControl ${rel.version}\n${rel.notes || ''}\n\nАгент на вашем ПК обновится сам.` + (rel.exe ? `\nНовая версия: ${C.publicUrl}/download/PC-PersonalControl.exe` : '')); sent++; await new Promise((r) => setTimeout(r, 60)); }
    }
    return reply(res, 200, { ok: true, version: rel.version, notified: sent });
  }
  // --- агент ---
  if (route === 'POST /api/v1/agent/register') {
    if (limited(ip, 10, 36e5)) return reply(res, 429, { error: 'rate_limited' });
    const b = await readBody(req, 4096), id = rnd(8), key = rnd(32);
    db.devices[id] = { keyHash: sha256(key), ownerId: '', name: str(b.name, 60) || 'Мой ПК', createdAt: Date.now() }; save();
    return reply(res, 200, Object.assign({ deviceId: id, deviceKey: key }, pairInfo(id)));
  }
  if (url.pathname.startsWith('/api/v1/agent/')) {
    const auth = deviceAuth(req);
    if (!auth) return reply(res, 401, { error: 'unknown_device' });
    const [id, dev] = auth;
    if (route === 'POST /api/v1/agent/pair-code') return reply(res, 200, dev.ownerId ? { paired: true } : Object.assign({ paired: false }, pairInfo(id)));
    if (route === 'POST /api/v1/agent/telemetry') {
      const b = await readBody(req, 65536); const d = clean(b);
      if (d.host) dev.name = d.host;
      snapshots.set(id, { at: Date.now(), data: d });
      return reply(res, 200, { ok: true, paired: !!dev.ownerId, fast: Date.now() - (viewed.get(id) || 0) < 60e3, release: relInfo(latest()) });
    }
    if (route === 'GET /api/v1/agent/poll') {
      const ready = pending(id);
      if (ready.length) return reply(res, 200, { commands: ready });
      const old = waiters.get(id); if (old) { clearTimeout(old.timer); reply(old.res, 200, { commands: [] }); }
      const timer = setTimeout(() => { waiters.delete(id); reply(res, 200, { commands: [] }); }, Math.min(25, Math.max(1, Number(url.searchParams.get('wait')) || 25)) * 1000);
      waiters.set(id, { res, timer });
      res.on('close', () => { const w = waiters.get(id); if (w && w.res === res) { clearTimeout(timer); waiters.delete(id); } });
      return;
    }
    if (route === 'POST /api/v1/agent/result') {
      const b = await readBody(req, 4096), c = commands.get(str(b.id, 32));
      if (c && c.deviceId === id) { c.status = b.ok ? 'done' : 'failed'; c.message = str(b.message, 200); }
      return reply(res, 200, { ok: true });
    }
    return reply(res, 404, { error: 'not_found' });
  }
  // --- Mini App ---
  if (url.pathname.startsWith('/api/v1/app/')) {
    const uid = verifyInitData(req.headers['x-telegram-init-data']);
    if (!uid) return reply(res, 401, { error: 'bad_init_data' });
    if (route === 'GET /api/v1/app/devices') {
      const out = myDevices(uid).map(([id, d]) => { const s = snapshots.get(id); return { id, name: d.name, online: !!s && Date.now() - s.at < ONLINE_MS, lastSeen: s ? s.at : null }; });
      return reply(res, 200, { devices: out, release: relInfo(latest()) });
    }
    let m = /^\/api\/v1\/app\/devices\/([0-9a-f]{16})\/(snapshot|command)$/.exec(url.pathname);
    if (m) {
      const dev = db.devices[m[1]];
      if (!dev || dev.ownerId !== uid) return reply(res, 404, { error: 'not_found' });
      const s = snapshots.get(m[1]), online = !!s && Date.now() - s.at < ONLINE_MS;
      viewed.set(m[1], Date.now());
      if (m[2] === 'snapshot' && req.method === 'GET') return reply(res, 200, { name: dev.name, online, at: s ? s.at : null, data: s ? s.data : null });
      if (m[2] === 'command' && req.method === 'POST') {
        const b = await readBody(req, 1024), action = String(b.action);
        if (!ACTIONS.has(action)) return reply(res, 400, { error: 'unknown_action' });
        if (!online) return reply(res, 409, { error: 'offline' });
        let arg = null;
        if (action === 'timer') { arg = Number(b.seconds); if (!Number.isInteger(arg) || arg < 1 || arg > 315360000) return reply(res, 400, { error: 'bad_seconds' }); }
        return reply(res, 200, { id: enqueue(m[1], action, arg).id });
      }
    }
    m = /^\/api\/v1\/app\/commands\/([0-9a-f]{16})$/.exec(url.pathname);
    if (m && req.method === 'GET') {
      const c = commands.get(m[1]), dev = c && db.devices[c.deviceId];
      if (!c || !dev || dev.ownerId !== uid) return reply(res, 404, { error: 'not_found' });
      if (c.status !== 'done' && c.status !== 'failed' && c.exp < Date.now()) { c.status = 'failed'; c.message = 'ПК не ответил вовремя — команда отменена.'; }
      return reply(res, 200, { status: c.status, message: c.message });
    }
  }
  return reply(res, 404, { error: 'not_found' });
}

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.exe': 'application/octet-stream', '.ps1': 'application/octet-stream' };
function serveFile(res, file, extra) {
  fs.stat(file, (e, st) => {
    if (e || !st.isFile()) return reply(res, 404, { error: 'not_found' });
    res.writeHead(200, Object.assign({ 'content-type': MIME[path.extname(file)] || 'application/octet-stream', 'content-length': st.size, 'cache-control': 'public, max-age=300' }, extra));
    fs.createReadStream(file).pipe(res);
  });
}
const server = http.createServer(async (req, res) => {
  res.setHeader('x-content-type-options', 'nosniff'); res.setHeader('referrer-policy', 'no-referrer');
  res.setHeader('content-security-policy', "default-src 'self'; script-src 'self' https://telegram.org; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'");
  try {
    const url = new URL(req.url, 'http://x');
    if (url.pathname.startsWith('/api/')) return await api(req, res, url);
    if (req.method !== 'GET') return reply(res, 405, { error: 'method' });
    if (url.pathname === '/download/FanPilot.exe' || url.pathname === '/download/PC-PersonalControl.exe') {
      const r = db.releases.filter((x) => x.exe).sort((a, b) => cmpVer(b.version, a.version))[0];
      return r ? (res.writeHead(302, { location: r.exe.url }), res.end()) : reply(res, 404, { error: 'no_release' });
    }
    const dl = /^\/dl\/((?:agent-\d+\.\d+\.\d+\.ps1)|(?:FanPilot-\d+\.\d+\.\d+\.exe))$/.exec(url.pathname);
    if (dl) return serveFile(res, path.join(C.dataDir, 'releases', dl[1]), dl[1].endsWith('.exe') ? { 'content-disposition': 'attachment; filename="PC-PersonalControl.exe"' } : {});
    const rel = url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname).replace(/^\/+/, '');
    const file = path.resolve(C.webDir, rel);
    if (!file.startsWith(C.webDir + path.sep)) return reply(res, 403, { error: 'forbidden' });
    return serveFile(res, file);
  } catch (e) {
    if (!res.headersSent) reply(res, e.code === 413 || e.code === 400 ? e.code : 500, { error: e.code ? e.message : 'server_error' });
    if (!e.code) log('error:', e.stack);
  }
});
if (require.main === module) { server.listen(C.port, () => log(`PC-PersonalControl Cloud на порту ${C.port}`)); botLoop(); }
module.exports = { server, verifyInitData, C };
