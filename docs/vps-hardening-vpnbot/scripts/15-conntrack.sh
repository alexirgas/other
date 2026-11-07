#!/bin/sh
# Шаг 15. conntrack: больше места в таблице соединений и более короткий таймаут «мёртвых» TCP-сессий.
#
# Зачем: ядро помнит каждое соединение через сервер (VPN-клиенты, nginx, DNS) в таблице conntrack. На VPS с 1 ГБ ОЗУ
# размер по умолчанию 8192 записей, а запись об установленном TCP-соединении живёт 5 суток (432000 с), даже если клиент
# давно пропал. Когда таблица заполняется, ядро молча отбрасывает пакеты НОВЫХ соединений: сервер «тупит», SSH зависает,
# в журнале ядра появляется «nf_conntrack: table full, dropping packet».
#
# Что ставит скрипт:
#   /etc/sysctl.d/99-conntrack.conf             nf_conntrack_max = 65536, nf_conntrack_tcp_timeout_established = 86400 (1 сутки)
#   /etc/modprobe.d/nf_conntrack-hashsize.conf  hashsize = 16384 (только если текущий меньше; на 2 ГБ ОЗУ ядро ставит больше само)
#   /etc/modules-load.d/nf_conntrack.conf       загрузка модуля nf_conntrack РАНЬШЕ применения sysctl. Без неё после перезагрузки
#                                               настройки из 99-conntrack.conf молча не применяются: systemd-sysctl стартует на 2-й секунде,
#                                               а nf_conntrack обычно подгружает позже Docker/iptables, и ключей net.netfilter.* ещё нет.
# Ничего не уменьшает: если max/hashsize уже больше, а таймаут короче, оставляет как есть.
# Перезапуск контейнеров не нужен. Цена: ~300 байт на запись, при заполнении 65536 это около 20 МБ ОЗУ.
# Свои значения: CT_MAX=131072 CT_TIMEOUT=43200 CT_HASH=32768 sh 15-conntrack.sh --apply
# Откат: удалить все три файла (99-conntrack.conf, nf_conntrack-hashsize.conf, nf_conntrack.conf в modules-load.d) и перезагрузить сервер.
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
MAX=${CT_MAX:-65536}; TO=${CT_TIMEOUT:-86400}; HASH=${CT_HASH:-16384}
CONF=/etc/sysctl.d/99-conntrack.conf; MP=/etc/modprobe.d/nf_conntrack-hashsize.conf; ML=/etc/modules-load.d/nf_conntrack.conf
P=/proc/sys/net/netfilter
[ -e $P/nf_conntrack_max ] || die "модуль nf_conntrack не загружен (запущен ли Docker?)"
cur_max=$(cat $P/nf_conntrack_max); cur_to=$(cat $P/nf_conntrack_tcp_timeout_established)
cur_hash=$(cat /sys/module/nf_conntrack/parameters/hashsize); cnt=$(cat $P/nf_conntrack_count)
say "сейчас: max=$cur_max, hashsize=$cur_hash, таймаут established=${cur_to}с, занято $cnt"
NEED_HASH=0; [ "$cur_hash" -lt "$HASH" ] && NEED_HASH=1
[ "$cur_max" -gt "$MAX" ] && MAX=$cur_max
[ "$cur_to" -gt 0 ] && [ "$cur_to" -lt "$TO" ] && TO=$cur_to
# чужие определения conntrack в других файлах перебили бы наши: не трогаем, пусть решает человек
other=$(grep -rlsE 'nf_conntrack' /etc/sysctl.conf /etc/sysctl.d /etc/modprobe.d 2>/dev/null | grep -vxE "$CONF|$MP" || true)
[ -z "$other" ] || die "conntrack уже задан в: $other - объедините настройки вручную"
want="# conntrack: capacity and timeout (vps-hardening step 15)
net.netfilter.nf_conntrack_max = $MAX
net.netfilter.nf_conntrack_tcp_timeout_established = $TO"
if [ -f "$CONF" ] && [ "$(cat "$CONF")" = "$want" ] && [ "$NEED_HASH" = 0 ] && [ -f "$ML" ]; then ok "уже настроено: max=$MAX, таймаут=${TO}с"; exit 0; fi
if [ "$APPLY" != 1 ]; then
  say "(dry-run) записал бы $CONF: max=$MAX, таймаут established=${TO}с, и $ML (загрузка модуля до sysctl)"
  [ "$NEED_HASH" = 1 ] && say "(dry-run) записал бы $MP: hashsize=$HASH и применил на лету"
  exit 0
fi
printf '%s\n' "$want" > "$CONF"
mkdir -p /etc/modules-load.d; echo nf_conntrack > "$ML"
sysctl -p "$CONF" >/dev/null || die "sysctl не принял $CONF"
if [ "$NEED_HASH" = 1 ]; then
  echo "options nf_conntrack hashsize=$HASH" > "$MP"
  echo "$HASH" > /sys/module/nf_conntrack/parameters/hashsize || warn "hashsize на лету не применился (применится после перезагрузки)"
fi
ok "conntrack: max=$(cat $P/nf_conntrack_max), таймаут=$(cat $P/nf_conntrack_tcp_timeout_established)с, hashsize=$(cat /sys/module/nf_conntrack/parameters/hashsize)"
