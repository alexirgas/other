#!/bin/sh
# Шаг 16. Сборщик метрик: раз в минуту одна строка в /var/log/vps-collect.log (для разбора «почему тупило»).
#
# Зачем: когда сервер тормозит, обычно уже поздно что-либо измерять. Сборщик ничего не меняет и почти ничего не стоит
# (десяток чтений из /proc, ~150 байт в минуту, ~200 КБ в сутки), зато потом видно, что было в нужную минуту.
#
# Формат строки:
#   2026-11-07_21:20:01 load=0.13 memav=1199M swap=0M ct=1083/65536 ctdrop=0 psi_cpu=3.75 psi_mem=0.00 psi_io=0.00 tcp=5 tw=0
#   load      - средняя нагрузка за минуту (сравнивайте с числом ядер: nproc)
#   memav     - доступная ОЗУ (MemAvailable); ниже ~100 МБ - опасно
#   swap      - занятый swap; растёт вместе с падением memav = не хватает памяти
#   ct=A/B    - записей conntrack занято / максимум; A близко к B = таблица почти полная
#   ctdrop    - счётчик отброшенных пакетов conntrack с загрузки; любой рост = были потери
#   psi_*     - доля времени (%), когда задачи ждали CPU / память / диск (avg10); больше ~10 держится = перегрузка
#   tcp, tw   - сокетов TCP всего и в TIME_WAIT
#
# Ставит: /usr/local/bin/vps-collect.sh, /etc/cron.d/vps-collect (каждую минуту), /etc/logrotate.d/vps-collect (14 дней, сжатие).
# Смотреть: tail -20 /var/log/vps-collect.log   или   grep '2026-11-07_21:' /var/log/vps-collect.log   (старые: zgrep ... .gz)
# Откат: rm /usr/local/bin/vps-collect.sh /etc/cron.d/vps-collect /etc/logrotate.d/vps-collect /var/log/vps-collect.log*
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
S=/usr/local/bin/vps-collect.sh; C=/etc/cron.d/vps-collect; L=/etc/logrotate.d/vps-collect
[ -d /etc/cron.d ] || die "нет /etc/cron.d (установите cron: apt-get install cron)"
if [ "$APPLY" != 1 ]; then say "(dry-run) установил бы $S, $C (каждую минуту) и $L (14 дней)"; exit 0; fi
cat > "$S" <<'COLLECT'
#!/bin/bash
# vps-collect: one line per minute for post-mortem of slowdowns (vps-hardening step 16)
ts=$(date +%F_%T)
read -r l1 _ < /proc/loadavg
ma=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo)
su=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{printf "%d",(t-f)/1024}' /proc/meminfo)
cc=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
cm=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
dr=0
if [ -r /proc/net/stat/nf_conntrack ]; then
  { read -r hdr; set -- $hdr; idx=0
    for n; do idx=$((idx+1)); [ "$n" = drop ] && break; done
    while read -r -a row; do dr=$((dr + 0x${row[idx-1]})); done
  } < /proc/net/stat/nf_conntrack
fi
psi() { awk '/^some/{split($2,a,"=");print a[2]}' /proc/pressure/$1 2>/dev/null; }
ti=$(awk '/^TCP:/{print $3}' /proc/net/sockstat)
tw=$(awk '/^TCP:/{print $7}' /proc/net/sockstat)
echo "$ts load=$l1 memav=${ma}M swap=${su}M ct=$cc/$cm ctdrop=$dr psi_cpu=$(psi cpu) psi_mem=$(psi memory) psi_io=$(psi io) tcp=$ti tw=$tw" >> /var/log/vps-collect.log
COLLECT
chmod 755 "$S"; bash -n "$S" || die "синтаксис $S"
echo '* * * * * root /usr/local/bin/vps-collect.sh' > "$C"; chmod 644 "$C"
cat > "$L" <<'LOGROTATE'
/var/log/vps-collect.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
}
LOGROTATE
"$S"; ok "сборщик установлен, первая строка:"; tail -n 1 /var/log/vps-collect.log
systemctl is-active cron >/dev/null 2>&1 && ok "cron работает: новые строки будут каждую минуту" || warn "служба cron не активна: systemctl enable --now cron"
