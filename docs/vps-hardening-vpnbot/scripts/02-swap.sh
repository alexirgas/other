#!/bin/sh
# Шаг 2. Файл подкачки (swap) 2 ГБ, swappiness=10 (swap только в крайнем случае).
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
SIZE=${SIZE:-2G}
if [ -n "$(swapon --show --noheadings)" ]; then ok "swap уже есть:"; swapon --show; exit 0; fi
[ -e /swapfile ] && die "/swapfile существует, но не подключён. Разберитесь вручную."
avail=$(df -Pm / | awk 'NR==2{print $4}'); [ "$avail" -gt 4096 ] || die "мало места на диске ($avail МБ)"
do_it "fallocate -l $SIZE /swapfile" fallocate -l "$SIZE" /swapfile
do_it "chmod 600 /swapfile" chmod 600 /swapfile
do_it "mkswap" mkswap /swapfile
do_it "swapon" swapon /swapfile
if [ "$APPLY" = 1 ]; then
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf; sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null
  ok "swap включён и прописан в /etc/fstab"; free -h | head -3
else say "(dry-run) добавил бы строку в /etc/fstab и vm.swappiness=10 в /etc/sysctl.d/99-swap.conf"; fi
