#!/bin/sh
# Шаг 4. Защита от «пропавшей сети после перезагрузки».
# Если IPv6 отключён через sysctl, а в /etc/network/interfaces остался блок "iface ... inet6",
# то при перезагрузке ifup падает на IPv6 и интерфейс может не подняться. Блок закомментируем.
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
I=/etc/network/interfaces
[ -f "$I" ] || { ok "нет $I (сеть настроена не через ifupdown), пропускаю"; exit 0; }
d=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)
grep -qE '^iface .* inet6 ' "$I" || { ok "в $I нет активного блока inet6"; exit 0; }
[ "$d" = 1 ] || { warn "IPv6 включён (disable_ipv6=0), блок inet6 может быть нужен. Ничего не меняю."; exit 0; }
say "найден активный inet6 при отключённом IPv6:"; grep -nE -A6 '^iface .* inet6 ' "$I" | sed 's/^/    /'
backup_file "$I"
if [ "$APPLY" = 1 ]; then
  awk '/^iface .* inet6 /{c=1; print "# " $0; next} c&&/^[ \t]+[^ \t]/{print "# " $0; next} {c=0; print}' "$I" > "$I.new" && mv "$I.new" "$I"
  IF=$(awk '$1=="iface"&&$3=="inet"{print $2; exit}' "$I")
  say "проверка ifup (ничего не поднимает):"; ifup -n -v "$IF" 2>&1 | grep -E 'configuring|ip ' | head
  ok "блок inet6 закомментирован. Копия: $BK/"
else say "(dry-run) закомментировал бы блок inet6 выше"; fi
