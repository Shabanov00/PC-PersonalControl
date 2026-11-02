(function () {
  'use strict';
  var tg = window.Telegram && window.Telegram.WebApp, initData = tg && tg.initData || '';
  var root = document.getElementById('root'), chips = document.getElementById('chips');
  var state = { devices: [], id: null, snap: null, release: null, timerOpen: false }, busy = false;
  if (tg) { tg.ready(); tg.expand(); }

  function h(tag, attrs, kids) {
    var e = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) { if (k === 'class') e.className = attrs[k]; else if (k.slice(0, 2) === 'on') e.addEventListener(k.slice(2), attrs[k]); else e.setAttribute(k, attrs[k]); });
    [].concat(kids == null ? [] : kids).forEach(function (c) { e.appendChild(typeof c === 'object' ? c : document.createTextNode(String(c))); });
    return e;
  }
  function toast(msg) { var t = document.getElementById('toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(toast.t); toast.t = setTimeout(function () { t.classList.remove('show'); }, 3200); }
  function api(path, opts) {
    opts = opts || {};
    return fetch('/api/v1/app' + path, { method: opts.method || 'GET', headers: { 'X-Telegram-Init-Data': initData, 'Content-Type': 'application/json' }, body: opts.body ? JSON.stringify(opts.body) : undefined })
      .then(function (r) { return r.json().then(function (j) { if (!r.ok) { var e = new Error(j.error || 'error'); e.code = r.status; throw e; } return j; }); });
  }
  function setBadge(on, text) { var b = document.getElementById('state'); b.className = 'badge' + (on ? ' on' : ''); b.lastChild.textContent = text; }
  function tempClass(v) { return v >= 85 ? 'hot' : v >= 70 ? 'warn' : 'ok'; }
  function pick(list, kind) {
    var c = list.filter(function (t) { return t.kind === kind; });
    var best = c.filter(function (t) { return /package|core \(tctl|tdie|gpu core|average|^cpu$/i.test(t.name); })[0];
    return best || c.sort(function (a, b) { return b.value - a.value; })[0] || null;
  }
  function tempCard(label, t, load) {
    var v = t ? Math.round(t.value) : null;
    return h('div', { class: 'card' }, [
      h('div', { class: 'tl' }, label),
      h('div', { class: 'tv ' + (v == null ? '' : tempClass(v)) }, v == null ? [h('small', {}, 'нет данных')] : [v, h('small', {}, ' °C')]),
      load != null ? h('div', {}, [h('div', { class: 'tl' }, 'Загрузка ' + Math.round(load) + '%'), h('div', { class: 'bar' }, h('b', { style: 'width:' + Math.min(100, load) + '%' }))]) : ''
    ]);
  }
  function ago(ms) { var s = Math.round((Date.now() - ms) / 1000); return s < 90 ? s + ' с назад' : s < 5400 ? Math.round(s / 60) + ' мин назад' : Math.round(s / 3600) + ' ч назад'; }

  function runCommand(action, seconds, label, needConfirm) {
    var go = function () {
      api('/devices/' + state.id + '/command', { method: 'POST', body: { action: action, seconds: seconds } }).then(function (r) {
        toast('Команда отправлена…');
        (function poll(n) {
          api('/commands/' + r.id).then(function (c) {
            if (c.status === 'done') toast('✅ ' + (c.message || label));
            else if (c.status === 'failed') toast('⚠️ ' + (c.message || 'Не удалось выполнить'));
            else if (n < 40) setTimeout(function () { poll(n + 1); }, 1500);
          });
        })(0);
      }).catch(function (e) { toast(e.message === 'offline' ? 'ПК сейчас не в сети.' : 'Ошибка: ' + e.message); });
    };
    if (needConfirm && tg && tg.showConfirm) tg.showConfirm(label + '? Несохранённые данные могут быть потеряны.', function (ok) { if (ok) go(); }); else go();
  }

  function render() {
    chips.textContent = '';
    if (state.devices.length > 1) state.devices.forEach(function (d) {
      chips.appendChild(h('button', { class: 'chip' + (d.id === state.id ? ' sel' : ''), onclick: function () { state.id = d.id; state.snap = null; load(); } }, d.name));
    });
    root.textContent = '';
    var s = state.snap;
    if (!state.devices.length) {
      root.appendChild(h('div', { class: 'card' }, [h('b', {}, 'Нет привязанных ПК'), h('p', {}, 'Скачайте PC-PersonalControl на компьютер, запустите и нажмите Start в Telegram.'), h('a', { class: 'btn primary', href: '/' }, 'Скачать PC-PersonalControl')]));
      setBadge(false, 'нет ПК'); return;
    }
    if (!s) { root.appendChild(h('p', {}, 'Загрузка…')); return; }
    document.getElementById('host').textContent = s.name;
    setBadge(s.online, s.online ? 'в сети' : 'не в сети');
    if (!s.online) root.appendChild(h('div', { class: 'note' }, 'ПК не отвечает' + (s.at ? ' (последние данные ' + ago(s.at) + ')' : '') + '. Он выключен, спит или нет интернета.'));
    var d = s.data;
    if (!d) { root.appendChild(h('p', {}, 'Данных пока нет.')); return; }
    if (state.release && d.agent && cmpVer(state.release.version, d.agent) > 0)
      root.appendChild(h('div', { class: 'note info' }, 'Вышла версия ' + state.release.version + ' — агент на ПК обновится сам, ничего делать не нужно.'));
    root.appendChild(h('h2', {}, 'Температуры'));
    root.appendChild(h('div', { class: 'grid' }, [tempCard('Процессор', pick(d.temps, 'cpu'), d.load.cpu), tempCard('Видеокарта', pick(d.temps, 'gpu'), d.load.gpu)]));
    var other = d.temps.filter(function (t) { return t.kind === 'other'; }).slice(0, 6);
    if (other.length) root.appendChild(h('div', { class: 'card', style: 'margin-top:11px' }, other.map(function (t) { return h('div', { class: 'row' }, [h('span', {}, t.hw + ' · ' + t.name), h('span', { class: tempClass(t.value) }, Math.round(t.value) + ' °C')]); })));
    root.appendChild(h('h2', {}, 'Вентиляторы'));
    root.appendChild(d.fans.length ? h('div', { class: 'card' }, d.fans.map(function (f) {
      return h('div', {}, [h('div', { class: 'row' }, [h('span', {}, f.hw + ' · ' + f.name), h('span', {}, (f.rpm != null ? Math.round(f.rpm) + ' об/мин' : '') + (f.percent != null ? (f.rpm != null ? ' · ' : '') + Math.round(f.percent) + '%' : ''))])]);
    })) : h('div', { class: 'card' }, h('p', {}, 'Плата не отдаёт показания вентиляторов.')));
    var sp = d.specs, rows = [['Процессор', sp.cpu.name + (sp.cpu.cores ? ' · ' + sp.cpu.cores + ' яд./' + sp.cpu.threads + ' пот.' : '')]]
      .concat(sp.gpu.map(function (g) { return ['Видеокарта', g.name + (g.vramMB ? ' · ' + Math.round(g.vramMB / 1024) + ' ГБ' : '')]; }))
      .concat([['Память', sp.ramGB + ' ГБ' + (d.load.ram != null ? ' · занято ' + Math.round(d.load.ram) + '%' : '')], ['Плата', sp.board], ['Система', sp.os]])
      .concat(sp.disks.map(function (k) { return ['Диск', k.name + ' · ' + k.sizeGB + ' ГБ']; }))
      .concat([['Работает', Math.floor(d.uptimeMin / 60) + ' ч ' + Math.round(d.uptimeMin % 60) + ' мин'], ['Версия агента', d.agent]]);
    root.appendChild(h('h2', {}, 'Характеристики'));
    root.appendChild(h('div', { class: 'card' }, rows.filter(function (r) { return r[1]; }).map(function (r) { return h('div', { class: 'row' }, [h('span', {}, r[0]), h('span', {}, r[1])]); })));
    root.appendChild(h('h2', {}, 'Управление'));
    var dis = s.online ? {} : { disabled: 'disabled' };
    function btn(label, fn, cls) { return h('button', Object.assign({ class: 'btn ' + (cls || ''), type: 'button', onclick: fn }, dis), label); }
    root.appendChild(h('div', { class: 'actions' }, [
      btn('🌙 Сон', function () { runCommand('sleep', null, 'Спящий режим', true); }),
      btn('🔒 Блокировка', function () { runCommand('lock', null, 'Блокировка'); }),
      btn('🔄 Перезагрузка', function () { runCommand('restart', null, 'Перезагрузка', true); }, 'red'),
      btn('⏻ Выключить', function () { runCommand('shutdown', null, 'Выключение', true); }, 'red'),
      btn('⏲ Таймер выключения', function () { state.timerOpen = !state.timerOpen; render(); }),
      btn('✖️ Отменить таймер', function () { runCommand('cancel', null, 'Таймер отменён'); })
    ]));
    if (state.timerOpen) {
      var n = h('input', { type: 'number', min: '1', max: '9999', value: '30', inputmode: 'numeric' });
      var u = h('select', {}, [h('option', { value: '60' }, 'мин'), h('option', { value: '3600' }, 'час'), h('option', { value: '86400' }, 'дн.')]);
      root.appendChild(h('div', { class: 'timer' }, [n, u, h('button', { class: 'btn primary', type: 'button', onclick: function () { var sec = Math.round(Number(n.value) * Number(u.value)); if (sec >= 1) { state.timerOpen = false; runCommand('timer', sec, 'Таймер установлен'); render(); } } }, 'Старт')]));
    }
    root.appendChild(h('div', { class: 'foot' }, 'Обновляется автоматически. Пароли панель не запрашивает.'));
  }
  function cmpVer(a, b) { var x = String(a).split('.'), y = String(b).split('.'); for (var i = 0; i < 3; i++) { var d = Number(x[i] || 0) - Number(y[i] || 0); if (d) return d; } return 0; }

  function load() {
    if (busy) return; busy = true;
    var p = state.id ? Promise.resolve() : api('/devices').then(function (r) { state.devices = r.devices; state.release = r.release; state.id = r.devices[0] && r.devices[0].id; });
    p.then(function () { return state.id ? api('/devices/' + state.id + '/snapshot').then(function (s) { state.snap = s; }) : null; })
      .then(render).catch(function (e) {
        root.textContent = ''; setBadge(false, 'ошибка');
        root.appendChild(h('div', { class: 'note' }, e.code === 401 ? 'Откройте панель из Telegram: через кнопку «Панель» у бота.' : 'Нет связи с сервером. Повторяю попытку…'));
      }).then(function () { busy = false; });
  }
  load();
  setInterval(function () { if (!document.hidden && !state.timerOpen) load(); }, 4000);
})();
