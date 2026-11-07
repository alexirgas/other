#!/bin/sh
# Шаг 3. Автоматические обновления безопасности Debian. Автоперезагрузки НЕТ
# (перезагрузка у нас раз в неделю по cron).
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
if dpkg -s unattended-upgrades >/dev/null 2>&1 && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then ok "unattended-upgrades уже включён"; exit 0; fi
if [ "$APPLY" = 1 ]; then
  echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades >/dev/null
  dpkg-reconfigure -f noninteractive unattended-upgrades
  cat /etc/apt/apt.conf.d/20auto-upgrades; systemctl is-enabled unattended-upgrades; unattended-upgrade --dry-run 2>&1 | tail -3
  ok "готово"
else say "(dry-run) apt-get install unattended-upgrades + включил бы ежедневные обновления безопасности"; fi
