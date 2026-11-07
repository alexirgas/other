#!/bin/sh
# Шаг 11. Раз в неделю, за минуту до плановой перезагрузки (время берётся из /etc/cron.d, иначе пт 04:19) очищать служебные логи бота.
# НЕ трогаются логи, которые бот использует для «Анализа подозрительных IP» и статистики
# (список KEEP ниже): их очищает владелец сам через меню бота «логи».
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
S=/usr/local/sbin/clear-vpnbot-logs.sh; C=/etc/cron.d/clear-vpnbot-logs
if [ "$APPLY" != 1 ]; then say "(dry-run) установил бы $S и $C (за минуту до плановой перезагрузки)"; exit 0; fi
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
# время: за минуту до плановой перезагрузки из /etc/cron.d (shutdown -r), иначе пятница 04:19
R=$(grep -hE '^[0-9]+ [0-9]+ \* \* [0-9*]+ .*(shutdown -r|reboot)' /etc/cron.d/* 2>/dev/null | grep -v clear-vpnbot | head -1)
CM=19; CH=4; CD=5
if [ -n "$R" ]; then
  set -f; set -- $R; set +f; rm_=$1; rh=$2; CD=$5
  if [ "$rm_" -ge 1 ]; then CM=$((rm_-1)); CH=$rh; elif [ "$rh" -ge 1 ]; then CM=59; CH=$((rh-1)); fi
  say "перезагрузка найдена: $R -> очистка в $CH:$CM (день недели $CD)"
else say "задание перезагрузки не найдено, ставлю пятницу 04:19"; fi
printf '# Weekly cleanup of service logs one minute before the reboot\n%s %s * * %s root /usr/local/sbin/clear-vpnbot-logs.sh\n' "$CM" "$CH" "$CD" > "$C"; chmod 644 "$C"
ok "установлено"; "$S" --dry-run
