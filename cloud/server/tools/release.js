#!/usr/bin/env node
'use strict';
// setup:   node tools/release.js setup --api https://example.com
// publish: node tools/release.js publish --version 1.0.1 --notes "Что нового" --server https://example.com --key ADMIN_KEY [--exe ../client/PC-PersonalControl.exe] [--no-notify]
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const keysDir = path.join(__dirname, '..', 'keys');
const agentPath = path.join(__dirname, '..', '..', 'client', 'FanPilotAgent.ps1');
const privPath = path.join(keysDir, 'release-private.pem');
const arg = (n, d) => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : d; };
const flag = (n) => process.argv.includes('--' + n);
const die = (m) => { console.error('Ошибка: ' + m); process.exit(1); };
const b64 = (u) => Buffer.from(u, 'base64url').toString('base64');

function pubXml(privPem) {
  const j = crypto.createPublicKey(crypto.createPrivateKey(privPem)).export({ format: 'jwk' });
  return `<RSAKeyValue><Modulus>${b64(j.n)}</Modulus><Exponent>${b64(j.e)}</Exponent></RSAKeyValue>`;
}
const cmd = process.argv[2];

if (cmd === 'setup') {
  const api = (arg('api') || '').replace(/\/+$/, '');
  if (!/^https:\/\/[^\s/]+$/.test(api)) die('укажите --api https://ваш-домен (без пути, только HTTPS)');
  if (!fs.existsSync(privPath)) {
    fs.mkdirSync(keysDir, { recursive: true });
    const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 3072 });
    fs.writeFileSync(privPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
    fs.writeFileSync(path.join(keysDir, '.gitignore'), '*\n');
    console.log('Создан закрытый ключ подписи: ' + privPath + '\nХРАНИТЕ ЕГО В СЕКРЕТЕ и сделайте резервную копию: без него нельзя выпускать обновления.');
  }
  let src = fs.readFileSync(agentPath, 'utf8');
  src = src.replace(/(\$script:ApiBase\s*=\s*')[^']*(')/, `$1${api}$2`)
    .replace(/(\$script:UpdatePublicKeyXml\s*=\s*')[^']*(')/, `$1${pubXml(fs.readFileSync(privPath, 'utf8'))}$2`);
  fs.writeFileSync(agentPath, src);
  console.log('FanPilotAgent.ps1 настроен: API = ' + api + ', открытый ключ обновлён.\nТеперь выполните Build-PC-PersonalControl.ps1 и опубликуйте релиз (publish).');
} else if (cmd === 'publish') {
  const version = arg('version'), server = (arg('server') || '').replace(/\/+$/, ''), key = arg('key') || process.env.ADMIN_KEY;
  if (!/^\d+\.\d+\.\d+$/.test(version || '')) die('--version X.Y.Z');
  if (!server || !key) die('нужны --server и --key (или переменная ADMIN_KEY)');
  if (!fs.existsSync(privPath)) die('нет ключа подписи, сначала выполните setup');
  const agent = fs.readFileSync(agentPath);
  const m = /\$script:AgentVersion\s*=\s*'([^']+)'/.exec(agent.toString('utf8'));
  if (!m || m[1] !== version) die(`в FanPilotAgent.ps1 AgentVersion = ${m ? m[1] : '?'}, а публикуется ${version}. Исправьте версию в файле.`);
  if (/'__API_BASE__'|'__PUBLIC_KEY_XML__'/.test(agent.toString('utf8'))) die('сначала выполните setup');
  const sign = (buf) => crypto.sign('sha256', buf, crypto.createPrivateKey(fs.readFileSync(privPath))).toString('base64');
  const body = { version, notes: arg('notes', ''), notify: !flag('no-notify'), agent_b64: agent.toString('base64'), agent_sig_b64: sign(agent) };
  if (arg('exe')) body.exe_b64 = fs.readFileSync(arg('exe')).toString('base64');
  fetch(server + '/api/v1/admin/release', { method: 'POST', headers: { 'content-type': 'application/json', 'x-admin-key': key }, body: JSON.stringify(body) })
    .then(async (r) => { const j = await r.json(); if (!r.ok) die(`${r.status} ${JSON.stringify(j)}`); console.log(`Опубликовано ${j.version}; уведомлено пользователей: ${j.notified}.`); })
    .catch((e) => die(e.message));
} else {
  console.log('Команды: setup --api https://домен | publish --version X.Y.Z --notes "..." --server https://домен --key КЛЮЧ [--exe путь] [--no-notify]');
}
