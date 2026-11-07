#!/bin/sh
# Общие функции. Подключается из остальных скриптов: . "$(dirname "$0")/lib.sh"
# Правило: без --apply скрипт НИЧЕГО не меняет, только показывает, что сделал бы.
APPLY=0
for _a in "$@"; do [ "$_a" = "--apply" ] && APPLY=1; done
BASE=${BASE:-/root/vpnbot_extra}          # папка с ботом (docker-compose.yml)
DATE=$(date +%Y%m%d)
BK=${BK:-/root/vps-fix-backup-$DATE}      # сюда складываются копии изменённых файлов

say()  { printf '%s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*"; }
die()  { bad "$*"; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "запускайте от root"; }
mode_banner() {
  if [ "$APPLY" = 1 ]; then say "=== РЕЖИМ: ПРИМЕНЕНИЕ (--apply) ==="; mkdir -p "$BK"; chmod 700 "$BK"
  else say "=== РЕЖИМ: ПРОБНЫЙ (dry-run), ничего не меняется. Для применения добавьте --apply ==="; fi
}
# do_it "описание" команда аргументы... : в пробном режиме печатает, в боевом выполняет
do_it() { _d=$1; shift
  if [ "$APPLY" = 1 ]; then say "+ $_d"; "$@" || die "не удалось: $_d"
  else say "(dry-run) $_d"; fi
}
backup_file() { [ "$APPLY" = 1 ] && [ -e "$1" ] && cp -a "$1" "$BK/$(echo "$1" | tr / _)" && say "копия: $1 -> $BK/"; return 0; }
# docker compose с теми же IP и VER, что у работающего бота (чтобы не сбить настройки)
dc() {
  _ip=${IP:-$(docker exec php printenv IP 2>/dev/null)}
  _ver=${VER:-$(docker exec php printenv VER 2>/dev/null)}
  [ -n "$_ip" ] || die "не удалось определить IP из контейнера php (запущен ли бот?)"
  ( cd "$BASE" && IP=$_ip VER=$_ver docker compose --env-file ./.env --env-file ./override.env "$@" )
}
