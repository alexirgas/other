#!/bin/sh
# Шаг 13. Автозапуск бота после перезагрузки: выбор варианта A / B / C.
# Запуск: sh 13-autostart.sh A [--apply]        (без варианта - только показывает текущее состояние)
#
#  A (РЕКОМЕНДУЕТСЯ, как на наших серверах): crontab "@reboot make r" + restart: unless-stopped у сервисов.
#     После загрузки Docker сам поднимает контейнеры, затем make r пересоздаёт их => ДВА старта (два сообщения
#     от бота в Telegram). Зато контейнер, упавший сам (например OOM на 1 ГБ ОЗУ), и контейнеры после
#     перезапуска Docker поднимаются автоматически.
#  B (как в оригинале mercurykd/vpnbot): crontab "@reboot make r", а restart: в compose ЗАКОММЕНТИРОВАН.
#     Старт один. Минус: упавший контейнер сам не поднимется, после перезапуска демона Docker контейнеры
#     остаются остановленными до make r / reboot.
#  C: без crontab, только restart: unless-stopped. Старт один, но make u при загрузке не выполняется:
#     нет bootstrap_config, ensure_bin, push_nodes. Не рекомендуется.
#
# Во всех вариантах: ровно ОДНА запись автозапуска (дубль /etc/cron.d/vpnbot-autostart удаляется - из-за него
# make r запускался дважды) и нефатальный git fetch (шаг 12).
. "$(dirname "$0")/lib.sh"; need_root
V=$(echo "${1:-}" | tr a-z A-Z)
CRON_LINE="@reboot cd $BASE && make r"
DC=$BASE/docker-compose.yml
RL='^[[:space:]]+restart: unless-stopped'
state() {
  say "--- текущее состояние ($BASE)"
  say "crontab root:"; crontab -l 2>/dev/null | grep -E 'make r' | sed 's/^/    /' || true
  [ -f /etc/cron.d/vpnbot-autostart ] && warn "есть дубль /etc/cron.d/vpnbot-autostart" || ok "дубля в /etc/cron.d нет"
  say "активных строк restart: unless-stopped в compose: $(grep -cE "$RL" "$DC") (закомментированных: $(grep -cE '^[[:space:]]+# restart: unless-stopped' "$DC"))"
  grep -qF "git fetch origin --quiet || true;" "$BASE/makefile" && ok "git fetch не фатален" || warn "git fetch фатален -> шаг 12"
}
case "$V" in A|B|C) ;; "") state; say "Выберите вариант: sh 13-autostart.sh A|B|C [--apply]"; exit 0;; *) die "вариант A, B или C";; esac
mode_banner; state
[ -f "$DC" ] || die "нет $DC"
if [ "$APPLY" != 1 ]; then say "(dry-run) вариант $V: см. описание в начале файла"; exit 0; fi
# 1. убрать дубль
if [ -f /etc/cron.d/vpnbot-autostart ]; then backup_file /etc/cron.d/vpnbot-autostart; rm -f /etc/cron.d/vpnbot-autostart; say "удалён /etc/cron.d/vpnbot-autostart"; fi
# 2. crontab
case "$V" in
  A|B) ( crontab -l 2>/dev/null | grep -v 'make r'; echo "$CRON_LINE" ) | crontab - ;;
  C)   ( crontab -l 2>/dev/null | grep -v 'make r' ) | crontab - 2>/dev/null || crontab -r 2>/dev/null || true ;;
esac
# 3. restart-политика в compose и у работающих контейнеров (без перезапуска)
backup_file "$DC"
case "$V" in
  A|C) sed -i 's/^\([[:space:]]*\)# restart: unless-stopped/\1restart: unless-stopped/' "$DC"; POL=unless-stopped;;
  B)   sed -i 's/^\([[:space:]]*\)restart: unless-stopped/\1# restart: unless-stopped/' "$DC"; POL=no;;
esac
dc config -q || { cp -a "$BK/$(echo "$DC" | tr / _)" "$DC"; die "compose не прошёл, вернул файл"; }
ids=$(docker ps -q); [ -z "$ids" ] || docker update --restart=$POL $ids >/dev/null
state; ok "вариант $V применён, перезапуска контейнеров не было. Эффект проявится при следующей перезагрузке."
