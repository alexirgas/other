#!/usr/bin/env bash
###############################################################################
#  VPNBot Extra - установка с нуля на чистый Debian 12 (шаг A гайда vps-hardening-vpnbot)
#
#  Как пользоваться:
#     bash 00-install-vpnbot.sh            # запуск (и повторный запуск после ребута)
#     bash 00-install-vpnbot.sh --check    # предполётная проверка, ничего не меняет
#     bash 00-install-vpnbot.sh --harden   # только этап 3 (защита и тюнинг) на уже установленном боте
#     bash 00-install-vpnbot.sh --extras   # только этап 4 (необязательные шаги 05-10: копия, обновления, починки)
#     bash 00-install-vpnbot.sh --reset    # забыть прогресс и начать сначала
#
#  Этапы (скрипт сам понимает, на каком вы находитесь):
#     1) Подготовка: SSH-порт, BBR, IPv6 off, swap, часовой пояс, расписание
#        перезагрузки, обновление системы  ->  ПЕРЕЗАГРУЗКА
#     2) Установка: закрытие порта 22, установка бота (init.sh форка), исправление
#        известных проблем форка, часовой пояс бота, автозапуск, проверка
#     3) Защита и тюнинг из гайда (шаги 03, 04, 11-16 + аудит): автообновления
#        безопасности, сеть после reboot, очистка логов, автозапуск без сюрпризов,
#        защита статистики трафика, conntrack, сборщик метрик
#     4) По желанию, с выбором по каждому шагу (установить / пропустить / сначала показать): резервная
#        копия (05), обновление nginx (06), PHP 8.3 (07), починки бота (08, 09), AdGuard Home (10)
#
#  Собрано из ручных заметок (смена порта, sysctl, часовой пояс, обновление, init.sh,
#  TZ бота, автозапуск, расписание перезагрузки) и скриптов этого гайда. Секретов внутри нет:
#  токен бота вводится при запуске, пароли и IP сюда не записываются.
#  Не проверялось end-to-end на чистом сервере: первый запуск делайте на новом пустом VPS.
###############################################################################
set -Eeuo pipefail

# ----------------------------- Настройки -------------------------------------
INIT_URL="https://raw.githubusercontent.com/ugam842-lab/vpnbot_extra/master/scripts/init.sh"
BRANCH="master"
BOT_DIR="/root/vpnbot_extra"
TZ_NAME="${TZ_NAME:-Europe/Moscow}"
DEFAULT_SSH_PORT=8934
# Откуда брать скрипты этапа 3 (этот же гайд). Можно закрепить версию: REPO_REF=<коммит или тег>
REPO_URL="${REPO_URL:-https://github.com/alexirgas/other.git}"
REPO_REF="${REPO_REF:-main}"
REPO_DIR="/root/other"
SCRIPTS_DIR="$REPO_DIR/docs/vps-hardening-vpnbot/scripts"
STATE_DIR="/root/.vpnbot-installer"
STATE_FILE="$STATE_DIR/stage"
PORT_FILE="$STATE_DIR/ssh_port"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o DPkg::Lock::Timeout=180
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
FAILED=()

# ----------------------------- Оформление ------------------------------------
C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_CYN=$'\e[36m'; C_OFF=$'\e[0m'
say()  { echo -e "\n${C_CYN}[+] $*${C_OFF}"; }
ok()   { echo -e "${C_GRN}    OK:${C_OFF} $*"; }
warn() { echo -e "${C_YEL}    [!] $*${C_OFF}"; }
err()  { echo -e "${C_RED}    [X] $*${C_OFF}"; }
pause_exit() { read -r -p "Нажми Enter, чтобы закрыть окно..." _ || true; }
die()  { err "$*"; pause_exit; exit 1; }

on_err() {
  local code=$?
  echo
  err "Скрипт остановился с ошибкой (строка $1, код $code)."
  echo "    Скопируй текст выше и пришли помощнику."
  echo "    Скрипт можно запустить заново - он продолжит с нужного этапа."
  pause_exit
  exit "$code"
}
trap 'on_err $LINENO' ERR

confirm() {   # confirm "Вопрос" y|n   (второй аргумент - ответ по умолчанию)
  local prompt="$1" def="${2:-n}" ans hint
  if [ "$def" = "y" ]; then hint="[Д/н]"; else hint="[д/Н]"; fi
  while true; do
    read -r -p "$prompt $hint: " ans || true
    ans="${ans:-$def}"
    case "${ans,,}" in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
    esac
    echo "    Ответь «д» (да) или «н» (нет)."
  done
}

# ----------------------------- Проверки --------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "Запусти от root (войди как root)."; exit 1; }

if [ "${1:-}" = "--reset" ]; then
  rm -rf "$STATE_DIR"
  echo "Прогресс сброшен. Запусти скрипт ещё раз."
  exit 0
fi

preflight() {
  echo "=== Предполётная проверка (ничего не меняется) ==="
  . /etc/os-release 2>/dev/null || true
  echo "Система:        ${PRETTY_NAME:-неизвестно}  (нужен Debian 12)"
  echo "Ядра / ОЗУ:     $(nproc) / $(free -m | awk '/Mem/{print $2}') МБ"
  echo "Диск /:         $(df -h / | awk 'NR==2{print $4" свободно из "$2" ("$5" занято)"}')"
  echo "Swap:           $(swapon --show --noheadings | awk '{print $1" "$3}' | tr '\n' ' ')$([ -z "$(swapon --show --noheadings)" ] && echo 'нет')"
  echo "SSH сейчас:     порты $(ss -tlnpH 2>/dev/null | grep sshd | awk '{n=split($4,a,":"); print a[n]}' | sort -un | tr '\n' ' ')"
  echo "Заняты 80/443:  $(ss -tlnH 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | grep -xE '80|443' | sort -u | tr '\n' ' ')$(ss -tlnH 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | grep -qxE '80|443' || echo 'свободны')"
  echo "IPv6 отключён:  $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo ?) (1 = да)"
  if [ -f /etc/network/interfaces ] && grep -qE '^iface .* inet6 ' /etc/network/interfaces; then
    echo "[!] В /etc/network/interfaces есть блок inet6: после отключения IPv6 сеть может не подняться (этап 3, шаг 04 это чинит)"
  fi
  echo "Docker:         $(command -v docker >/dev/null 2>&1 && docker --version || echo 'не установлен (поставит init.sh форка)')"
  echo "Папка бота:     $([ -d "$BOT_DIR" ] && echo "есть: $BOT_DIR" || echo 'нет (чистая установка)')"
  for u in https://raw.githubusercontent.com https://github.com https://api.telegram.org; do
    if curl -fsS -m 10 -o /dev/null "$u" 2>/dev/null || [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)" != "000" ]; then
      echo "Доступ к $u: есть"; else echo "[!] Нет доступа к $u (проверьте сеть/DNS на сервере)"; fi
  done
  echo "Состояние установщика: $(cat "$STATE_FILE" 2>/dev/null || echo 'новый запуск')"
}
if [ "${1:-}" = "--check" ]; then preflight; exit 0; fi

if ! grep -q '^ID=debian' /etc/os-release || ! grep -q '^VERSION_ID="12"' /etc/os-release; then
  warn "Скрипт рассчитан на Debian 12, а здесь другая система."
  confirm "Продолжить на свой страх и риск?" n || exit 1
fi

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

# Запуск внутри screen: если оборвётся SSH, установка не прервётся.
# Вернуться в сессию: screen -r vpnbot
if [ -z "${STY:-}" ] && [ -z "${TMUX:-}" ] && [ "${NO_SCREEN:-0}" != "1" ] && [ -f "$SCRIPT_PATH" ]; then
  if ! command -v screen >/dev/null 2>&1; then
    apt-get update -y -o DPkg::Lock::Timeout=180 >/dev/null
    apt-get install "${APT_OPTS[@]}" screen >/dev/null
  fi
  echo "Запускаю установщик внутри screen (защита от обрыва связи)..."
  sleep 1
  exec screen -S vpnbot bash "$SCRIPT_PATH" "$@"
fi

STAGE="$(cat "$STATE_FILE" 2>/dev/null || echo new)"

###############################################################################
#                           Функции этапа 1
###############################################################################
valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
  return 0
}
reserved_port() {
  case "$1" in
    80|443|8443|33443|51821|53|3000|8081|853|5443|6060|67|68) return 0 ;;
  esac
  return 1
}

ask_ssh_port() {
  echo
  echo "Порт SSH - это «дверь», через которую ты заходишь на сервер."
  echo "Стандартный 22 постоянно атакуют боты, поэтому лучше сменить."
  while true; do
    read -r -p "Новый порт SSH (1-65535) [${DEFAULT_SSH_PORT}]: " p || true
    p="${p:-$DEFAULT_SSH_PORT}"
    if ! valid_port "$p"; then err "Нужно число от 1 до 65535."; continue; fi
    if reserved_port "$p"; then err "Порт $p занят под VPN/бота. Выбери другой."; continue; fi
    SSH_PORT="$p"; break
  done
}

ask_schedule() {
  SCHEDULE=""; SCHEDULE_LABEL=""
  echo
  echo "Регулярная перезагрузка сервера помогает ему «освежиться»."
  echo "Рекомендуем: пятница 04:40 (так на всех наших серверах, очистка логов встанет за минуту до неё)."
  if ! confirm "Создать расписание перезагрузки?" y; then return 0; fi

  local names=("Понедельник" "Вторник" "Среда" "Четверг" "Пятница" "Суббота" "Воскресенье")
  echo "День перезагрузки:"
  local i
  for i in 0 1 2 3 4 5 6; do echo "   $((i+1))) ${names[$i]}"; done
  echo "   8) Ежедневно"
  local d h m
  while true; do
    read -r -p "Выбери номер [5]: " d || true
    d="${d:-5}"
    if [[ "$d" =~ ^[1-8]$ ]]; then break; fi
    err "Введи число от 1 до 8."
  done
  while true; do
    read -r -p "Час (0-23) [4]: " h || true
    h="${h:-4}"
    if [[ "$h" =~ ^[0-9]{1,2}$ ]] && [ $((10#$h)) -le 23 ]; then break; fi
    err "Час - число от 0 до 23."
  done
  while true; do
    read -r -p "Минуты (0-59) [40]: " m || true
    m="${m:-40}"
    if [[ "$m" =~ ^[0-9]{1,2}$ ]] && [ $((10#$m)) -le 59 ]; then break; fi
    err "Минуты - число от 0 до 59."
  done
  h=$((10#$h)); m=$((10#$m))
  local dow="*" label="ежедневно"
  if [ "$d" -le 7 ]; then dow="$d"; label="${names[$((d-1))]}"; fi
  SCHEDULE="$m $h * * $dow"
  SCHEDULE_LABEL="$label в $(printf '%02d:%02d' "$h" "$m") ($TZ_NAME)"
}

setup_ssh() {
  local port="$1"
  say "Меняю порт SSH на $port"
  if [ "$port" = "22" ]; then ok "Порт 22 оставлен без изменений"; return 0; fi

  cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
  mkdir -p /etc/ssh/sshd_config.d
  # убираем чужие строки Port, чтобы sshd не слушал лишние порты
  sed -i -E 's/^[[:space:]]*Port[[:space:]]+.*/#&/' /etc/ssh/sshd_config
  local f
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [ -e "$f" ] || continue
    [ "$f" = "/etc/ssh/sshd_config.d/10-port.conf" ] && continue
    sed -i -E 's/^[[:space:]]*Port[[:space:]]+.*/#&/' "$f"
  done
  # Порт 22 пока остаётся как страховка - закроем на этапе 2
  printf 'Port %s\nPort 22\n' "$port" > /etc/ssh/sshd_config.d/10-port.conf

  if ! sshd -t; then
    rm -f /etc/ssh/sshd_config.d/10-port.conf
    die "Ошибка в конфиге sshd - изменения отменены, порт не менялся."
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "${port}/tcp" >/dev/null
    ok "ufw: порт $port открыт"
  fi
  systemctl restart ssh
  sleep 2
  if ss -tln | grep -q ":${port} "; then
    ok "sshd слушает порт $port (порт 22 пока тоже открыт как страховка)"
  else
    die "sshd не слушает порт $port. Порт 22 остался рабочим - зайди по нему и напиши помощнику."
  fi
}

setup_sysctl() {
  say "Включаю BBR, настраиваю сеть и отключаю IPv6"
  modprobe tcp_bbr 2>/dev/null || true
  echo tcp_bbr > /etc/modules-load.d/bbr.conf
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    warn "BBR недоступен на этом сервере (часто бывает на OpenVZ/LXC) - это не критично."
  fi
  cat > /etc/sysctl.d/99-vpn-tuning.conf <<'EOF'
# Congestion Control and Queueing
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Memory Settings
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 16384 262144 67108864
net.ipv4.tcp_wmem = 32768 524288 67108864
net.core.netdev_max_backlog = 10240
net.core.somaxconn = 8192

# Fast Open and Reuse
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1

# Connection Timeouts and Keepalive
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_syn_backlog = 10240
net.ipv4.tcp_max_tw_buckets = 5000

# Port Range
net.ipv4.ip_local_port_range = 10000 65000

# Filesystem and Additional
fs.file-max = 51200
fs.inotify.max_user_instances = 8192

# Advanced Settings
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_mem = 25600 51200 102400
net.ipv4.udp_mem = 25600 51200 102400

# DISABLE IPV6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null 2>&1 || warn "Часть параметров не применилась (это нормально для виртуальных серверов)."
  ok "congestion_control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)"
  ok "ipv6 отключён: $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo ?) (1 = да)"
}

setup_swap() {
  say "Файл подкачки (swap)"
  if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then ok "swap уже есть, не трогаю"; return 0; fi
  if [ -e /swapfile ]; then warn "/swapfile существует, но не подключён - пропускаю, разберись вручную"; return 0; fi
  local total_mb avail_mb size_mb
  total_mb=$(df -Pm / | awk 'NR==2{print $2}'); avail_mb=$(df -Pm / | awk 'NR==2{print $4}')
  # маленький диск (до 20 ГБ) - 1 ГБ swap, иначе 2 ГБ (см. шаг 18 гайда)
  if [ "$total_mb" -lt 20000 ]; then size_mb=1024; else size_mb=2048; fi
  if [ "$avail_mb" -lt $((size_mb + 2048)) ]; then warn "Мало места на диске ($avail_mb МБ) - swap не создаю"; return 0; fi
  fallocate -l "${size_mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
  sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null || true
  ok "swap ${size_mb} МБ включён и прописан в /etc/fstab (swappiness=10)"
}

setup_timezone() {
  say "Часовой пояс сервера: $TZ_NAME"
  timedatectl set-timezone "$TZ_NAME"
  ok "$(timedatectl | grep 'Time zone' | sed 's/^ *//')"
}

setup_schedule() {
  if [ -n "$SCHEDULE" ]; then
    say "Расписание перезагрузки: $SCHEDULE_LABEL"
    cat > /etc/cron.d/reboot-job <<EOF
# Плановая перезагрузка сервера: $SCHEDULE_LABEL
$SCHEDULE root /sbin/shutdown -r now
EOF
    chmod 644 /etc/cron.d/reboot-job
    systemctl enable --now cron >/dev/null 2>&1
    ok "Создан /etc/cron.d/reboot-job"
  else
    rm -f /etc/cron.d/reboot-job
    ok "Плановая перезагрузка не настроена"
  fi
}

###############################################################################
#                                ЭТАП 1
###############################################################################
stage1() {
  clear || true
  echo "=================================================================="
  echo "  VPNBot Extra - установка. ЭТАП 1 из 4: подготовка сервера"
  echo "=================================================================="
  echo "Я задам два вопроса. В скобках [ ] - значение по умолчанию:"
  echo "если оно подходит, просто нажми Enter."

  ask_ssh_port
  ask_schedule

  echo
  echo "------------------------ ПРОВЕРЬ НАСТРОЙКИ -----------------------"
  echo "  Порт SSH:              $SSH_PORT"
  echo "  Часовой пояс:          $TZ_NAME"
  if [ -n "$SCHEDULE" ]; then
    echo "  Перезагрузка:          $SCHEDULE_LABEL"
  else
    echo "  Перезагрузка:          не нужна"
  fi
  echo "  Ещё будет сделано:     BBR, отключение IPv6, swap, обновление системы"
  echo "------------------------------------------------------------------"
  echo
  warn "ВАЖНО: если у хостера есть файрвол (Firewall / Сетевой экран /"
  warn "Группы безопасности) в панели управления - ОТКРОЙ там входящий"
  warn "TCP-порт $SSH_PORT ДО продолжения, иначе потеряешь доступ."
  confirm "Всё верно, начинаем?" y || { echo "Отменено. Запусти скрипт заново."; exit 0; }

  echo "$SSH_PORT" > "$PORT_FILE"

  say "Устанавливаю базовые пакеты"
  apt-get update -y -o DPkg::Lock::Timeout=180
  apt-get install "${APT_OPTS[@]}" cron wget curl ca-certificates screen

  setup_ssh "$SSH_PORT"
  setup_sysctl
  setup_swap
  setup_timezone
  setup_schedule

  say "Обновляю систему (это может занять несколько минут)"
  apt-get update -y -o DPkg::Lock::Timeout=180
  apt-get "${APT_OPTS[@]}" full-upgrade
  apt-get autoremove --purge -y
  apt-get clean

  echo "prepped" > "$STATE_FILE"

  echo
  echo "=================================================================="
  echo "  ЭТАП 1 ЗАВЕРШЁН. Сейчас сервер перезагрузится."
  echo "=================================================================="
  echo "  Что делать дальше:"
  echo "   1. Подожди 1-2 минуты."
  echo "   2. Подключись заново, но уже по НОВОМУ порту: $SSH_PORT"
  echo "      (в MobaXterm: Session -> SSH -> поле Port)"
  echo "   3. Выполни:  bash $SCRIPT_PATH"
  echo "      Скрипт сам продолжит с этапа 2."
  echo
  echo "Перезагрузка через 15 секунд (Ctrl+C - отменить)..."
  sleep 15
  reboot
}

###############################################################################
#                           Функции этапа 2
###############################################################################
finalize_ssh() {
  local port; port="$(cat "$PORT_FILE" 2>/dev/null || echo 22)"
  [ "$port" = "22" ] && return 0
  [ -f /etc/ssh/sshd_config.d/10-port.conf ] || return 0
  grep -q '^Port 22$' /etc/ssh/sshd_config.d/10-port.conf || return 0

  say "Закрываю порт 22 (остаётся только $port)"
  local cur="${SSH_CONNECTION##* }"
  local do_close=0
  if [ "$cur" = "$port" ]; then
    ok "Ты подключён по порту $port - значит, он работает."
    do_close=1
  else
    warn "Не удалось убедиться, что ты зашёл по порту $port (подключение: ${cur:-неизвестно})."
    if confirm "Ты ТОЧНО подключён по порту $port и вход работает? Закрыть порт 22?" n; then
      do_close=1
    fi
  fi
  if [ "$do_close" -eq 1 ]; then
    sed -i '/^Port 22$/d' /etc/ssh/sshd_config.d/10-port.conf
    sshd -t
    systemctl restart ssh
    ok "Порт 22 закрыт. Текущая сессия не прервётся."
  else
    warn "Порт 22 оставлен открытым. Позже закрыть можно так:"
    warn "  sed -i '/^Port 22\$/d' /etc/ssh/sshd_config.d/10-port.conf && systemctl restart ssh"
  fi
}

ask_token() {
  echo
  echo "Токен бота получают у @BotFather в Telegram (команда /newbot,"
  echo "или /token для существующего бота). Выглядит так: 1234567890:AAH..."
  echo "Если токен когда-то светился в чате/скриншотах - выпусти новый (/revoke)."
  while true; do
    read -r -s -p "Вставь токен (символы не отображаются) и нажми Enter: " TOKEN || true
    echo
    TOKEN="${TOKEN//[[:space:]]/}"
    if ! [[ "$TOKEN" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]]; then
      err "Это не похоже на токен. Должно быть: цифры, двоеточие, длинный набор символов."
      continue
    fi
    local resp
    resp="$(curl -fsS -m 20 "https://api.telegram.org/bot${TOKEN}/getMe" 2>/dev/null || true)"
    if echo "$resp" | grep -q '"ok":true'; then
      local uname
      uname="$(echo "$resp" | grep -o '"username":"[^"]*"' | cut -d'"' -f4 || true)"
      ok "Telegram подтвердил токен${uname:+: бот @$uname}"
      break
    fi
    warn "Telegram не подтвердил токен (неверный токен или нет доступа к api.telegram.org)."
    if confirm "Использовать этот токен всё равно?" n; then break; fi
  done
}

restore_ensure_bin() {
  cd "$BOT_DIR"
  if [ -f scripts/ensure_bin.sh ]; then
    ok "scripts/ensure_bin.sh на месте"
    return 0
  fi
  warn "В форке отсутствует scripts/ensure_bin.sh - ищу в истории git"
  local c
  for c in $(git log --all --format=%h -- scripts/ensure_bin.sh 2>/dev/null); do
    if git cat-file -e "$c:scripts/ensure_bin.sh" 2>/dev/null; then
      git show "$c:scripts/ensure_bin.sh" > scripts/ensure_bin.sh
      chmod +x scripts/ensure_bin.sh
      ok "Файл восстановлен из коммита $c"
      return 0
    fi
  done
  die "Не нашёл ensure_bin.sh ни в рабочей папке, ни в истории. Пришли помощнику вывод: cd $BOT_DIR && git log --oneline | head"
}

set_bot_timezone() {
  local envf="$BOT_DIR/.env"
  if [ ! -f "$envf" ]; then
    (cd "$BOT_DIR" && bash scripts/bootstrap_config.sh) || true
  fi
  [ -f "$envf" ] || die "Не найден $envf"
  cp -a "$envf" "$envf.bak.$(date +%s)"
  if grep -q '^TZ=' "$envf"; then
    sed -i "s|^TZ=.*|TZ=$TZ_NAME|" "$envf"
  else
    echo "TZ=$TZ_NAME" >> "$envf"
  fi
  ok "Часовой пояс бота: $(grep '^TZ=' "$envf")"
}

# Базовый автозапуск: одна строка в crontab root. Дубль в /etc/cron.d не создаём (из-за него
# `make r` запускался дважды). Нефатальный git fetch и политика restart ставятся на этапе 3 (шаги 12, 13).
setup_autostart() {
  say "Автозапуск бота после перезагрузки сервера"
  rm -f /etc/cron.d/vpnbot-autostart
  if crontab -l 2>/dev/null | grep -qF "make r"; then
    ok "строка автозапуска в crontab уже есть"
  else
    ( crontab -l 2>/dev/null || true; echo "@reboot cd $BOT_DIR && make r" ) | crontab -
    ok "добавлено в crontab root: @reboot cd $BOT_DIR && make r"
  fi
  systemctl enable --now cron >/dev/null 2>&1
}

check_containers() {
  local tries=0 missing
  while [ "$tries" -lt 6 ]; do
    missing=""
    local n
    for n in php ng xr tg; do
      docker ps --format '{{.Names}}' | grep -qx "$n" || missing="$missing $n"
    done
    [ -z "$missing" ] && return 0
    tries=$((tries+1)); sleep 10
  done
  warn "Не запущены контейнеры:$missing"
  return 1
}

###############################################################################
#                                ЭТАП 2
###############################################################################
stage2() {
  clear || true
  echo "=================================================================="
  echo "  VPNBot Extra - ЭТАП 2 из 4: установка бота"
  echo "=================================================================="

  finalize_ssh

  if [ -d "$BOT_DIR" ] && [ -f "$BOT_DIR/makefile" ]; then
    warn "Папка $BOT_DIR уже существует - установщик бота пропускаю, только чиню и перезапускаю."
  else
    ask_token

    say "Скачиваю установщик форка"
    apt-get update -y -o DPkg::Lock::Timeout=180 >/dev/null
    apt-get install "${APT_OPTS[@]}" curl wget git make ca-certificates >/dev/null
    wget -q -O /root/vpnbot-init.sh "$INIT_URL" || die "Не удалось скачать $INIT_URL (проверь интернет на сервере)."
    [ -s /root/vpnbot-init.sh ] || die "Скачанный init.sh пустой."
    head -c 2 /root/vpnbot-init.sh | grep -q '#!' || die "Скачанный init.sh не похож на скрипт."
    ok "init.sh скачан ($(wc -c < /root/vpnbot-init.sh) байт) -> /root/vpnbot-init.sh"

    say "Устанавливаю бота (Docker, зависимости, код). Это 5-15 минут - не закрывай окно"
    if ! sh /root/vpnbot-init.sh "$TOKEN" "$BRANCH"; then
      warn "init.sh завершился с ошибкой - это ожидаемо при известной проблеме форка. Пробую исправить."
    fi
    unset TOKEN
  fi

  [ -d "$BOT_DIR" ] || die "Папка $BOT_DIR не появилась - установка не удалась."

  say "Проверяю известную проблему форка (ensure_bin.sh)"
  restore_ensure_bin

  say "Настраиваю часовой пояс бота"
  set_bot_timezone

  say "Запускаю бота (сборка образов - несколько минут)"
  cd "$BOT_DIR"
  make r

  say "Проверяю, что контейнеры работают"
  if check_containers; then
    ok "Контейнеры php, ng, xr, tg запущены"
  else
    warn "Что-то не поднялось. Выполни: cd $BOT_DIR && docker compose logs --tail=50"
  fi
  docker ps --format 'table {{.Names}}\t{{.Status}}'

  setup_autostart

  echo "installed" > "$STATE_FILE"
}

###############################################################################
#                       ЭТАП 3: защита и тюнинг из гайда
###############################################################################
fetch_scripts() {
  command -v git >/dev/null 2>&1 || apt-get install "${APT_OPTS[@]}" git >/dev/null
  rm -rf "$REPO_DIR"
  if git clone -q --depth 1 --branch "$REPO_REF" "$REPO_URL" "$REPO_DIR" 2>/dev/null \
     || { git clone -q "$REPO_URL" "$REPO_DIR" && git -C "$REPO_DIR" checkout -q "$REPO_REF"; }; then
    [ -d "$SCRIPTS_DIR" ] || return 1
    sed -i 's/\r$//' "$SCRIPTS_DIR"/*.sh
    ok "скрипты гайда скачаны: $SCRIPTS_DIR (версия $(git -C "$REPO_DIR" rev-parse --short HEAD))"
    return 0
  fi
  return 1
}

run_step() {   # run_step "Описание" файл [аргументы...]
  local title="$1" file="$2"; shift 2
  say "$title"
  if [ ! -f "$SCRIPTS_DIR/$file" ]; then warn "нет $file"; FAILED+=("$file"); return 0; fi
  if BASE="$BOT_DIR" sh "$SCRIPTS_DIR/$file" "$@"; then
    ok "$file выполнен"
  else
    warn "$file завершился с ошибкой - продолжаю, разберёшь позже: BASE=$BOT_DIR sh $SCRIPTS_DIR/$file $*"
    FAILED+=("$file")
  fi
}

stage3() {
  echo "=================================================================="
  echo "  VPNBot Extra - ЭТАП 3 из 4: защита и тюнинг (скрипты гайда)"
  echo "=================================================================="
  echo "Это безопасные шаги, каждый можно повторять. Они ничего не удаляют, контейнеры не перезапускают:"
  echo "  03 автообновления безопасности   04 сеть после перезагрузки   11 очистка логов раз в неделю"
  echo "  12 автозапуск не ломается без GitHub   13 автозапуск (вариант A)   14 защита статистики трафика"
  echo "  15 conntrack (против «тупит под нагрузкой»)   16 сборщик метрик   + итоговый аудит"
  if ! confirm "Применить эти шаги сейчас?" y; then
    warn "Пропущено. Позже: bash $SCRIPT_PATH --harden  (или шаги из README гайда по одному)"
    return 0
  fi
  say "Скачиваю скрипты гайда ($REPO_URL, версия $REPO_REF)"
  if ! fetch_scripts; then
    warn "Не удалось скачать скрипты гайда. Бот установлен и работает; шаги 03, 04, 11-16 сделайте позже вручную по README."
    warn "Особенно шаг 12: без него после перезагрузки бот может не подняться, если GitHub не пустит git fetch."
    return 0
  fi
  run_step "Автообновления безопасности (шаг 03)"            03-unattended-upgrades.sh --apply
  run_step "Сеть: защита от пропавшей сети после reboot (шаг 04)" 04-ipv6-ifupdown.sh --apply
  run_step "git fetch в makefile не фатален (шаг 12)"        12-fix-makefile-fetch.sh --apply
  run_step "Автозапуск бота, вариант A (шаг 13)"             13-autostart.sh A --apply
  run_step "Очистка служебных логов раз в неделю (шаг 11)"   11-log-cleanup.sh --apply
  run_step "Защита статистики трафика (шаг 14)"              14-xray-stats-guard.sh --apply
  run_step "conntrack: лимит и таймаут (шаг 15)"             15-conntrack.sh --apply
  run_step "Сборщик метрик (шаг 16)"                         16-collector.sh --apply
  say "Итоговый аудит (только чтение)"
  BASE="$BOT_DIR" sh "$SCRIPTS_DIR/audit.sh" || true
  if [ "${#FAILED[@]}" -gt 0 ]; then
    warn "Не выполнились шаги: ${FAILED[*]}"
    warn "Шаг 14 на только что установленном боте может не сработать, пока нет файла статистики: повторите через день: BASE=$BOT_DIR sh $SCRIPTS_DIR/14-xray-stats-guard.sh --apply"
  fi
}

###############################################################################
#          ЭТАП 4 (по желанию): резервная копия, обновления, починки бота
###############################################################################
CHOICE=""; SKIPALL=0

need_scripts() {
  [ -d "$SCRIPTS_DIR" ] && return 0
  say "Скачиваю скрипты гайда ($REPO_URL, версия $REPO_REF)"
  fetch_scripts
}

today_backup_exists() { [ -f "/root/vpnbot-backup-$(date +%Y%m%d).tar.gz" ]; }

ask_choice() {   # ask_choice "Заголовок" "Описание"  ->  CHOICE = install | skip | dry | skipall
  local a
  while true; do
    echo
    echo -e "${C_CYN}------------------------------------------------------------------${C_OFF}"
    echo -e "${C_CYN}$1${C_OFF}"
    echo -e "$2"
    echo
    read -r -p "  [у] установить   [п] пропустить   [с] сначала показать, что будет сделано   [в] пропустить все остальные   (Enter = пропустить): " a || true
    case "${a,,}" in
      у|y|д|да|install)        CHOICE=install; return 0 ;;
      ""|п|n|н|нет|skip)       CHOICE=skip;    return 0 ;;
      с|s|show)                CHOICE=dry;     return 0 ;;
      в|v|q|все)               CHOICE=skipall; return 0 ;;
      *) echo "    Введи у, п, с или в." ;;
    esac
  done
}

extra_step() {   # extra_step файл "Заголовок" "Описание" [нужна_копия: 0|1]
  local file="$1" title="$2" desc="$3" needs="${4:-0}"
  if [ "$SKIPALL" -eq 1 ]; then return 0; fi
  while true; do
    ask_choice "$title" "$desc"
    case "$CHOICE" in
      skipall) SKIPALL=1; warn "остальные необязательные шаги пропущены"; return 0 ;;
      skip)    warn "пропущено: $file"; return 0 ;;
      dry)     say "Пробный запуск $file (ничего не меняется)"
               BASE="$BOT_DIR" sh "$SCRIPTS_DIR/$file" || warn "пробный запуск завершился с ошибкой (см. выше)" ;;
      install)
        if [ "$needs" = 1 ] && ! today_backup_exists; then
          warn "Для этого шага нужна свежая резервная копия (шаг 05), а сегодня её ещё нет."
          if confirm "Сделать резервную копию сейчас?" y; then
            run_step "Резервная копия (шаг 05)" 05-backup.sh --apply
          else
            warn "Без копии шаг не выполняется - пропущено: $file"; return 0
          fi
        fi
        run_step "$title" "$file" --apply
        return 0 ;;
    esac
  done
}

stage4() {
  echo
  echo "=================================================================="
  echo "  VPNBot Extra - ЭТАП 4 из 4 (по желанию): копия, обновления, починки"
  echo "=================================================================="
  echo "По каждому шагу я покажу описание, а ты выберешь: установить / пропустить /"
  echo "сначала показать, что будет сделано (пробный запуск ничего не меняет)."
  echo "Шаги 06, 07 и 10 перезапускают часть контейнеров: бот замолчит на 30-60 секунд."
  echo "Не делай этого в минуты плановой перезагрузки сервера."
  if ! confirm "Перейти к необязательным шагам?" y; then
    warn "Пропущено. Позже: bash $SCRIPT_PATH --extras"
    return 0
  fi
  if ! need_scripts; then
    warn "Не удалось скачать скрипты гайда - этап 4 пропущен. Позже: bash $SCRIPT_PATH --extras"
    return 0
  fi
  SKIPALL=0
  extra_step 05-backup.sh "Шаг 05. Резервная копия (рекомендуется до шагов 06-10)" \
"  Что делает: архив папки бота (конфиги, ключи, сертификаты) -> /root/vpnbot-backup-ДАТА.tar.gz;
  на образы бота ставятся теги :backup-ДАТА (откат за минуту); копия AdGuardHome.yaml и тома AdGuard.
  Ничего не перезапускает, около минуты.
  Важно: архив содержит СЕКРЕТЫ. Скачай его к себе (scp) и не клади в публичный GitHub.
  Нужен для шагов 06, 07 и 10 (без него они не запускаются)." 0
  extra_step 06-nginx-alpine.sh "Шаг 06. Обновить nginx (контейнеры ng и up): 1.24 -> 1.28+" \
"  Что делает: пересобирает образ nginx на свежем Alpine. Сначала собирает ТЕСТОВЫЙ образ, сравнивает nginx -t
  у старого и нового, и только если результат одинаков - подменяет и пересоздаёт ng и up.
  Перезапуск: ng и up, бот молчит ~30-60 секунд. Нужна резервная копия (шаг 05).
  Откат: печатается в конце (тег backup-ДАТА). Зачем: старый nginx больше не получает исправлений безопасности." 1
  extra_step 07-php83.sh "Шаг 07. PHP 8.1 -> 8.3 (контейнеры php и service)" \
"  Что делает: правит dockerfile/php.dockerfile и docker-compose.yml, собирает тестовый образ и проверяет его
  (версия, набор модулей не уже старого, php -l для ВСЕХ файлов бота, qrencode), потом подменяет.
  Перезапуск: php и service, бот молчит ~30-60 секунд. Нужна резервная копия (шаг 05).
  Важно: правки лежат только на сервере; обновление бота из git (make u / меню) может их затереть - тогда повтори шаг.
  Зачем: PHP 8.1 снят с поддержки." 1
  extra_step 08-fix-vless-probe.sh "Шаг 08. Починка ложной ошибки проверки VLESS-ключа в меню бота" \
"  Что делает: правит 1 строку awk в app/traits/UserPortalTrait.php (из-за неё кнопка проверки ключа всегда писала
  «не прошла»). Делает копию оригинала, проверяет php -l, при ошибке возвращает оригинал.
  Ничего не перезапускает. Если в твоей версии форка этого бага нет, скрипт скажет об этом и ничего не тронет." 0
  extra_step 09-fix-bot-texts.sh "Шаг 09. Починка «знаков вопроса» вместо иконок и текстов бота" \
"  Что делает: в app/bot.php возвращает иконки уведомлений в меню IP и два текста («Доступ к торрентам ...»,
  «Обмен между пользователями ...»). Правка делается, только если шаблон найден ровно один раз; затем php -l.
  Ничего не перезапускает. Если в твоей версии форка этого бага нет, скрипт скажет об этом и ничего не тронет." 0
  extra_step 10-adguard.sh "Шаг 10. Обновить AdGuard Home (контейнер ad)" \
"  Что делает: собирает свежий образ, проверяет, что новая версия принимает твой конфиг, пересоздаёт ТОЛЬКО ad.
  Перезапуск: ad, DNS у клиентов пропадёт на несколько секунд. Нужна резервная копия (шаг 05):
  AdGuard сам меняет схему конфига при старте, поэтому копия AdGuardHome.yaml и тома обязательна." 1
  say "Состояние контейнеров"
  docker ps --format 'table {{.Names}}\t{{.Status}}'
  if [ "${#FAILED[@]}" -gt 0 ]; then warn "Не выполнились шаги: ${FAILED[*]}"; fi
}
final_message() {
  local ip port; ip="$(hostname -I | awk '{print $1}')"; port="$(cat "$PORT_FILE" 2>/dev/null || echo 22)"
  echo
  echo "=================================================================="
  echo "  ГОТОВО!"
  echo "=================================================================="
  echo "  1. Открой своего бота в Telegram и отправь /start"
  echo "  2. В хостере должны быть открыты входящие порты:"
  echo "       TCP $port (SSH), TCP 80, TCP 443, UDP 443, UDP 51821"
  echo "  3. Привяжи домен: A-запись домена -> $ip (AAAA-записи быть не должно,"
  echo "     IPv6 на сервере отключён). Домен затем указывается в настройках бота."
  echo "  4. Вход на сервер: ssh -p $port root@$ip"
  echo "  5. Перезапуск бота:  cd $BOT_DIR && make r"
  echo "  6. Логи бота:        cd $BOT_DIR && docker compose logs --tail=50"
  echo "  7. ДАЛЬШЕ ВРУЧНУЮ (README гайда): шаг 1 - вход по SSH-ключу и запрет пароля (сначала ключ!),"
  echo "     шаги 5-10 (копия, обновления, починки), если пропустил на этапе 4: bash $SCRIPT_PATH --extras"
  cat <<EOF
     Ключ на сервер (PowerShell на твоём компьютере). Если ключа ещё нет:
       ssh-keygen -t ed25519 -f "\$env:USERPROFILE\.ssh\id_ed25519_vps"
     Положить его на сервер:
       \$pub = (Get-Content "\$env:USERPROFILE\.ssh\id_ed25519_vps.pub" -Raw).Trim()
       ssh -p $port root@$ip "mkdir -p /root/.ssh && chmod 700 /root/.ssh && (grep -qxF '\$pub' /root/.ssh/authorized_keys 2>/dev/null || echo '\$pub' >> /root/.ssh/authorized_keys) && chmod 600 /root/.ssh/authorized_keys && echo KEY_OK"
     Проверь вход по ключу в НОВОМ окне и только потом (на сервере): sh $SCRIPTS_DIR/01-ssh-key-only.sh --apply
EOF
  echo "=================================================================="
  pause_exit
}

###############################################################################
case "${1:-}" in
  --harden) stage3; exit 0 ;;
  --extras) stage4; exit 0 ;;
esac

case "$STAGE" in
  new)       stage1 ;;
  prepped)   stage2; stage3; echo "hardened" > "$STATE_FILE"; stage4; echo "done" > "$STATE_FILE"; final_message ;;
  installed) stage3; echo "hardened" > "$STATE_FILE"; stage4; echo "done" > "$STATE_FILE"; final_message ;;
  hardened)  stage4; echo "done" > "$STATE_FILE"; final_message ;;
  done)
    echo "Установка уже выполнена."
    docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true
    echo
    echo "Защита и тюнинг заново:      bash $SCRIPT_PATH --harden"
    echo "Необязательные шаги 05-10:   bash $SCRIPT_PATH --extras"
    echo "Начать заново:               bash $SCRIPT_PATH --reset"
    pause_exit
    ;;
  *) die "Неизвестное состояние '$STAGE'. Запусти: bash $SCRIPT_PATH --reset" ;;
esac