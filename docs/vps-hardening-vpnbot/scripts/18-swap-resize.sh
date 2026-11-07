#!/bin/sh
# Шаг 18. Уменьшить swap-файл (по умолчанию до 1 ГБ). Для маленьких дисков (10 ГБ), где 2 ГБ swap - слишком много.
#
# Когда нужно: шаг 02 создаёт 2 ГБ. На диске 10 ГБ это пятая часть, а реально swap почти не используется (десятки МБ,
# swappiness=10). 1 ГБ swap всё ещё надёжно страхует от убийства контейнеров по памяти. На дисках 20+ ГБ можно не трогать.
#
# Как работает: swapoff -> новый файл /swapfile.new нужного размера -> mkswap -> замена /swapfile -> swapon.
# Запись в /etc/fstab не меняется. Скрипт останавливается, если занятый swap не помещается в свободную ОЗУ
# (иначе swapoff мог бы вызвать нехватку памяти), или если мало места на диске. Если что-то пошло не так после swapoff,
# старый swap включается обратно. Контейнеры не перезапускаются.
# Свой размер: SWAP_MB=1536 sh 18-swap-resize.sh --apply
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
MB=${SWAP_MB:-1024}
cur=$(swapon --noheadings --bytes --show=NAME,SIZE | awk '$1=="/swapfile"{print int($2/1048576)}')
[ -n "$cur" ] || die "/swapfile не подключён (нечего уменьшать)"
[ "$cur" -le "$MB" ] && { ok "swap уже ${cur} МБ (цель ${MB} МБ)"; exit 0; }
used=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print int((t-f)/1024)}' /proc/meminfo)
av=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
disk=$(df -Pm / | awk 'NR==2{print $4}')
say "swap сейчас ${cur} МБ, занято ${used} МБ; ОЗУ доступно ${av} МБ; свободно на диске ${disk} МБ; цель ${MB} МБ"
[ "$used" -lt "$MB" ] || die "занятый swap (${used} МБ) не помещается в новый размер"
[ "$av" -gt $((used * 2 + 100)) ] || die "мало свободной ОЗУ для безопасного swapoff"
[ "$disk" -gt $((MB + 200)) ] || die "мало места на диске для нового файла"
[ -e /swapfile.new ] && die "/swapfile.new уже существует, удалите вручную"
if [ "$APPLY" != 1 ]; then say "(dry-run) заменил бы /swapfile ${cur} МБ на ${MB} МБ"; exit 0; fi
swapoff /swapfile || die "swapoff не удался"
back() { rm -f /swapfile.new; swapon /swapfile 2>/dev/null; die "$1 (старый swap включён обратно)"; }
fallocate -l "${MB}M" /swapfile.new || back "fallocate не удался"
chmod 600 /swapfile.new
mkswap /swapfile.new >/dev/null || back "mkswap не удался"
mv /swapfile.new /swapfile
swapon /swapfile || die "swapon не удался: проверьте /swapfile вручную"
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
ok "swap теперь ${MB} МБ"; swapon --show; df -h / | awk 'NR==2{print "диск /: занято "$3" из "$2" ("$5")"}'
