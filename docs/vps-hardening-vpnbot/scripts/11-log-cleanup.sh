#!/bin/sh
# Шаг 11. Раз в неделю (пт 04:19, за минуту до перезагрузки в 04:20) очищать служебные логи бота.
# НЕ трогаются логи, которые бот использует для «Анализа подозрительных IP» и статистики
# (список KEEP ниже): их очищает владелец сам через меню бота «логи».
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
S=/usr/local/sbin/clear-vpnbot-logs.sh; C=/etc/cron.d/clear-vpnbot-logs
if [ "$APPLY" != 1 ]; then say "(dry-run) установил бы $S и $C (пт 04:19)"; exit 0; fi
cat > "$S" <<'SCRIPT'
#!/bin/sh
# Очистка служебных логов vpnbot_extra. --dry-run: только показать.
D=${D:-/root/vpnbot_extra/logs}
KEEP=" nginx_default_access nginx_domain_access nginx_tlgrm_access nginx_doh_access upstream_access xray xray_access vless-probe.sh letsencrypt.log "
DRY=0; [ "$1" = "--dry-run" ] && DRY=1
for f in "$D"/*; do
  [ -f "$f" ] || continue
  n=$(basename "$f")
  case "$KEEP" in *" $n "*) echo "KEEP  $n"; continue;; esac
  if [ $DRY = 1 ]; then echo "CLEAR $n"; else truncate -s 0 "$f"; fi
done
[ $DRY = 1 ] || logger -t clear-vpnbot-logs "service logs cleared in $D"
SCRIPT
chmod 755 "$S"; sh -n "$S" || die "синтаксис"
printf '# Weekly cleanup of service logs one minute before the Friday reboot\n19 4 * * 5 root /usr/local/sbin/clear-vpnbot-logs.sh\n' > "$C"; chmod 644 "$C"
ok "установлено"; "$S" --dry-run
