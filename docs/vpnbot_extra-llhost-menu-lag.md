# vpnbot_extra на LLHOST: `/menu` отвечает ~20 секунд

Форк: https://github.com/ugam842-lab/vpnbot_extra
Сервер: виртуальный арендованный (LLHOST), Debian 12, IPv6 отключён.

## Симптом

- Главное меню (`/menu`) в Telegram-боте открывается около 20 секунд.
- Остальные кнопки (например `/xray`, `/menu config`) отвечают сразу.
- Нагрузка на сервер нулевая, сеть до `api.telegram.org` быстрая (~120 мс).

## Причина

Главное меню собирает статусы сервисов через `scripts/menu_status.sh`
(бот ходит по ssh в контейнер `svc` и запускает скрипт). Результат кешируется на 60 секунд.

В скрипте есть проверка WARP: `docker exec wp wgcf trace`. Без IPv6 контейнер `wp`
пытается резолвить `cloudflare.com` через IPv6-адрес DNS Cloudflare, получает
`network is unreachable` и ждёт ~20 секунд. Скрипт после этого переходит
к запасной проверке и всё равно выдаёт `warp: on`, то есть результат для меню не меняется,
но каждый пересчёт кеша стоит 20 секунд.

## Диагностика

1. Замерить скрипт напрямую:

   ```bash
   docker exec svc sh -c 'time sh /scripts/menu_status.sh'
   ```

   Если `real` около 20 секунд при `user`/`sys` около нуля, скрипт чего-то ждёт.

2. Замерить проверку WARP отдельно:

   ```bash
   docker exec wp sh -c 'time wgcf trace'
   ```

   Ожидаемо: ровно ~20 секунд и ошибка `dial udp [2606:4700:4700::1111]:53: connect: network is unreachable`.

(Если нужно увидеть тайминги внутри бота: в `/config/pac.json` ключ `log_levels` →
`{"php_webhook": "on"}`, лог пишется в `/logs/webhook`. Внимание: в нём строка с URI
вебхука содержит токен бота. После диагностики выключить и удалить лог.)

## Исправление

Ограничить `wgcf trace` по времени. Править нужно **на хосте**: в контейнер `svc`
файл смонтирован отдельным файлом только для чтения, поэтому `sed -i` внутри контейнера
не работает («Resource busy»).

```bash
cd /root/vpnbot_extra
cp scripts/menu_status.sh /root/menu_status.sh.bak-before-timeout
sed -i 's/docker exec wp wgcf trace/docker exec wp timeout 3 wgcf trace/' scripts/menu_status.sh
grep -n "wgcf trace" scripts/menu_status.sh
```

После `sed -i` на хосте появляется новый файл, а bind mount держится за старый,
поэтому контейнер нужно перезапустить:

```bash
docker restart svc
docker exec svc sh -c 'grep -n "wgcf trace" /scripts/menu_status.sh; time sh /scripts/menu_status.sh'
```

Должна быть строка с `timeout 3`, время скрипта около 4 секунд (было ~21).
Повторные нажатия `/menu` в пределах 60 секунд мгновенные благодаря кешу.

## Результат

- Пересчёт статусов: ~21 с → ~3,9 с, результат тот же.
- `/menu` на практике отвечает сразу, так как статус берётся из кеша.

## Замечания

- Правка лежит в рабочей копии форка: после `git pull` файл может быть перезаписан,
  тогда замену нужно повторить.
- Чтобы вообще убрать 3 секунды ожидания, можно пропускать `wgcf trace` и сразу идти
  в запасную проверку (`curl -m 1` через контейнер `xr`) либо исправить DNS в контейнере `wp`,
  чтобы он не обращался к IPv6-адресу. IPv6 при этом включать не нужно.

## Про патч с таймаутами cURL из чата vpnbot

В оригинальном `mercurykd/vpnbot` в `request()` добавляют
`CURLOPT_CONNECTTIMEOUT => 5` и `CURLOPT_TIMEOUT => 15`, чтобы бот не зависал
на запросах к Telegram. В форке `vpnbot_extra` это уже есть
(`/app/bot.php`, функция `request()`: 5 и 20 секунд), добавлять ничего не нужно.
Кроме того, в форке по умолчанию используется вебхук, а цикл `getUpdates`
(`/app/polling.php`) включается только при `polling_mode: 1` в `pac.json`.
