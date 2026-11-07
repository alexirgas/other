#!/bin/sh
# Аудит сервера с vpnbot_extra. ТОЛЬКО ЧТЕНИЕ - ничего не меняет.
# Запуск: sh audit.sh        Итог: строки [ OK ] / [WARN] / [FAIL] / [INFO] и счётчики в конце.
# Каждая строка FAIL/WARN подсказывает, каким скриптом исправить.
export LC_ALL=C
BASE=${BASE:-/root/vpnbot_extra}
P=0; W=0; F=0
ok()   { P=$((P+1)); printf '[ OK ] %s\n' "$*"; }
warn() { W=$((W+1)); printf '[WARN] %s\n' "$*"; }
bad()  { F=$((F+1)); printf '[FAIL] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
hdr()  { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "запускайте от root"; exit 1; }

hdr "1. SSH"
sshd -T 2>/dev/null > /tmp/.sshd_t.$$
g() { awk -v k="$1" '$1==k{print $2; exit}' /tmp/.sshd_t.$$; }
[ "$(g passwordauthentication)" = no ] && ok "вход по паролю выключен" || bad "вход по паролю ВКЛЮЧЁН -> 01-ssh-key-only.sh"
case "$(g permitrootlogin)" in prohibit-password|without-password|no) ok "root только по ключу";; *) bad "root может входить по паролю -> 01-ssh-key-only.sh";; esac
[ "$(g kbdinteractiveauthentication)" = no ] && ok "keyboard-interactive выключен" || warn "kbd-interactive включён -> 01"
[ "$(g maxauthtries)" -le 3 ] 2>/dev/null && ok "MaxAuthTries <= 3" || warn "MaxAuthTries больше 3 -> 01"
[ -s /root/.ssh/authorized_keys ] && ok "в authorized_keys есть ключ" || bad "нет ключа в /root/.ssh/authorized_keys"
info "порт SSH: $(g port)"; rm -f /tmp/.sshd_t.$$

hdr "2. Память и диск"
if [ -n "$(swapon --show --noheadings)" ]; then ok "swap есть ($(free -m | awk '/Swap/{print $2}') МБ)"; else bad "swap нет -> 02-swap.sh"; fi
[ "$(cat /proc/sys/vm/swappiness)" -le 20 ] && ok "swappiness $(cat /proc/sys/vm/swappiness)" || warn "swappiness $(cat /proc/sys/vm/swappiness) (рекомендуется 10) -> 02"
u=$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}'); [ "$u" -lt 80 ] && ok "диск / занят на $u%" || warn "диск / занят на $u%"
info "ОЗУ: $(free -m | awk '/Mem/{print $2" МБ, доступно "$7" МБ"}')"

hdr "3. Обновления системы"
dpkg -s unattended-upgrades >/dev/null 2>&1 && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null && ok "unattended-upgrades включён" || bad "автообновления безопасности не настроены -> 03-unattended-upgrades.sh"
n=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst'); [ "$n" -lt 10 ] && ok "ожидают обновления: $n" || warn "ожидают обновления: $n пакетов (apt-get upgrade)"
[ -f /var/run/reboot-required ] && warn "нужна перезагрузка (reboot-required)" || ok "перезагрузка не требуется"
info "ядро: $(uname -r), аптайм: $(uptime -p)"

hdr "4. Сеть и перезагрузка"
d=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
if [ -f /etc/network/interfaces ] && grep -qE '^iface .* inet6 ' /etc/network/interfaces; then
  [ "$d" = 1 ] && bad "IPv6 выключен, но в /etc/network/interfaces активен inet6: после перезагрузки сеть может не подняться -> 04-ipv6-ifupdown.sh" || ok "inet6 активен и IPv6 включён (согласовано)"
else ok "конфликта inet6 нет"; fi
grep -rqsE 'reboot|^@reboot' /etc/cron.d /etc/crontab /var/spool/cron 2>/dev/null && ok "найдено задание перезагрузки в cron" || info "еженедельной перезагрузки в cron не видно"

hdr "5. Бот vpnbot_extra"
if [ ! -d "$BASE" ]; then warn "нет $BASE - остальные проверки пропущены"; else
  down=$(docker ps -a --format '{{.Names}} {{.Status}}' | grep -v ' Up ' | head); [ -z "$down" ] && ok "все контейнеры работают ($(docker ps -q | wc -l) шт.)" || bad "не работают: $down"
  ng=$(docker exec ng nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'); case "$ng" in 1.2[6-9].*|1.[3-9][0-9].*) ok "nginx $ng";; *) warn "nginx $ng устарел -> 06-nginx-alpine.sh";; esac
  pv=$(docker exec php php -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'); case "$pv" in 8.3.*|8.4.*|8.[5-9].*) ok "PHP $pv";; *) bad "PHP $pv (Alpine 3.18, без обновлений) -> 07-php83.sh";; esac
  av=$(docker exec ad /opt/adguardhome/AdGuardHome --version 2>/dev/null | grep -oE 'v[0-9.]+'); info "AdGuard Home $av (сверьте с последним релизом: github.com/AdguardTeam/AdGuardHome/releases) -> 10-adguard.sh"
  grep -q "awk 'BEGIN{RS=" "$BASE/app/traits/UserPortalTrait.php" 2>/dev/null && bad "баг awk в проверке VLESS-ключа -> 08-fix-vless-probe.sh" || ok "проверка VLESS-ключа: баг awk не найден"
  if grep -q "return '??';" "$BASE/app/bot.php" 2>/dev/null; then bad "иконки уведомлений = '??' -> 09-fix-bot-texts.sh"; else ok "иконки уведомлений в порядке"; fi
  grep -qF "'?????? ? ?????????" "$BASE/app/bot.php" 2>/dev/null && bad "тексты про торренты/обмен испорчены -> 09-fix-bot-texts.sh" || ok "тексты про торренты/обмен в порядке"
  m=$(grep -c '????' "$BASE/app/bot.php" 2>/dev/null); info "строк с '????' в bot.php: $m (остаток в комментариях безвреден)"
  ls /root/vpnbot-backup-*.tar.gz >/dev/null 2>&1 && ok "есть архив бота: $(ls /root/vpnbot-backup-*.tar.gz | tail -1)" || bad "нет архива /root/vpnbot-backup-*.tar.gz -> 05-backup.sh"
  docker images --format '{{.Tag}}' | grep -q '^backup-' && ok "есть образы с тегом backup-*" || warn "нет образов backup-* (откат образов невозможен) -> 05"
  [ -f /etc/cron.d/clear-vpnbot-logs ] && ok "очистка логов по cron настроена" || warn "очистка служебных логов не настроена -> 11-log-cleanup.sh"
  for c in $(docker ps --format '{{.Names}}'); do
    mx=$(docker inspect "$c" --format '{{index .HostConfig.LogConfig.Config "max-size"}}'); [ -n "$mx" ] || nolim="$nolim $c"
  done
  [ -z "$nolim" ] && ok "у всех контейнеров ограничен размер docker-логов" || warn "нет ограничения docker-логов у:$nolim (проверьте /etc/docker/daemon.json)"
  l=$(du -sm "$BASE/logs" 2>/dev/null | cut -f1); [ "${l:-0}" -lt 200 ] && ok "папка logs: ${l} МБ" || warn "папка logs: ${l} МБ (рост nginx_domain_access)"
  (cd "$BASE" && git status --short 2>/dev/null | head -8 | sed 's/^/        /') | grep -q . && info "в репозитории бота есть локальные правки (git status) - обновление app/ из git их затрёт, см. README"
fi

hdr "6. Информация (не меняем по решению владельца)"
info "права на config/*, cert_private, app/config.php, logs: НЕ ТРОГАЕМ (ломает работу контейнеров и бота)"
info "слушающие порты: $(ss -tulnH 2>/dev/null | awk '{print $1"/"$5}' | sed 's/.*://' | sort -u | tr '\n' ' ')"
info "журнал systemd: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]')"

printf '\nИТОГ: OK=%s  WARN=%s  FAIL=%s\n' "$P" "$W" "$F"
[ "$F" = 0 ]
