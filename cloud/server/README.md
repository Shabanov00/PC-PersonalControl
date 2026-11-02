# PC-PersonalControl Cloud

Сервер включает API для агентов, общего Telegram-бота и сайт в `web/`. Требуется Node.js 18 или новее; внешние npm-зависимости не используются.

## Запуск
1. В @BotFather создайте бота, затем `/newapp`/Menu Button не нужен: сервер сам ставит кнопку «Панель».
2. Нужен публичный HTTPS-домен (Caddy/nginx/Cloudflare перед `PORT`).
3. ```
   Set-Location .\cloud\server
   $env:BOT_TOKEN = '...'
   $env:BOT_USERNAME = 'MyPersonalControlBot'
   $env:PUBLIC_URL = 'https://example.com'
   $env:ADMIN_KEY = '<случайная строка от 24 символов>'
   node .\server.js
   ```
   Данные хранятся в `data/db.json`, загруженные релизы — в `data/releases/`. Настройте резервное копирование `data/`.

## Первый релиз
```
node .\tools\release.js setup --api https://example.com
# Из корня репозитория в PowerShell:
& .\cloud\client\Build-PC-PersonalControl.ps1
node .\tools\release.js publish --version 1.0.0 --notes "Первый релиз" --server https://example.com --key $env:ADMIN_KEY --exe ..\client\PC-PersonalControl.exe
```
`keys/release-private.pem` — закрытый ключ подписи. Храните его отдельно и не загружайте на сервер: владелец ключа может выпускать обновления для всех агентов.

## Выпуск обновления для всех
Измените `$script:AgentVersion` в `../client/FanPilotAgent.ps1`, затем опубликуйте релиз с той же версией. Агенты проверяют SHA-256 и RSA-подпись обновления. Параметр `--no-notify` отключает Telegram-уведомления. Чтобы приложить настольное приложение, передайте `--exe ..\client\PC-PersonalControl.exe`; сервер сохраняет старый URL загрузки `/download/FanPilot.exe` для совместимости.
Обновления API и бота применяются после перезапуска сервера.

## Безопасность
- Ключ устройства хранится на ПК под DPAPI, на сервере только его SHA-256.
- Mini App проверяется по подписи Telegram `initData`; доступ только владельцу устройства.
- Команды: фиксированный список, живут 2 минуты (устаревшая команда не сработает после пробуждения ПК).
- Сервер получает имя ПК, характеристики оборудования, температуры и обороты. Файлы, экран и пароли не передаются.
