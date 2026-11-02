(function () {
  'use strict';
  function h(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text) e.textContent = text; return e; }
  fetch('/api/v1/info').then(function (r) { return r.json(); }).then(function (i) {
    if (/^[A-Za-z0-9_]{4,64}$/.test(i.botUsername || '')) { var b = document.getElementById('bot'); b.href = 'https://t.me/' + i.botUsername; b.hidden = false; }
  }).catch(function () {});
  fetch('/api/v1/releases').then(function (r) { return r.json(); }).then(function (j) {
    var box = document.getElementById('rels'); box.textContent = '';
    if (!j.releases.length) { box.appendChild(h('p', '', 'Релизов пока нет.')); return; }
    document.getElementById('ver').lastChild.textContent = 'версия ' + j.releases[0].version;
    if (!j.releases.some(function (r) { return r.exe; })) document.getElementById('dl').hidden = true;
    j.releases.forEach(function (r) {
      var d = h('div', 'rel'); d.appendChild(h('b', '', r.version + ' · ' + new Date(r.date).toLocaleDateString('ru-RU')));
      d.appendChild(h('div', '', r.notes || 'Улучшения и исправления.'));
      if (r.exe) d.appendChild(h('div', '', 'SHA-256 установщика: ' + r.exe.sha256));
      box.appendChild(d);
    });
  }).catch(function () { document.getElementById('rels').textContent = 'Не удалось загрузить список.'; });
})();
