#!/bin/sh
# Шаг 12. КРИТИЧНО для перезагрузки. Автозапуск после reboot делает `make r` = остановить контейнеры + `make u`.
# В `make u` первой строкой идёт `git fetch origin` с форка бота. Если GitHub просит логин
# (could not read Username), fetch падает, make прерывается и контейнеры ОСТАЮТСЯ ОСТАНОВЛЕННЫМИ:
# после перезагрузки бот лежит, пока не запустить вручную. Правка: fetch больше не фатален (|| true).
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
M=$BASE/makefile; [ -f "$M" ] || die "нет $M"
O='git fetch origin $$branch --quiet || git fetch origin --quiet; \'
if grep -qF -- "git fetch origin --quiet || true;" "$M"; then ok "makefile уже исправлен"; exit 0; fi
[ "$(grep -cF -- "$O" "$M")" = 1 ] || die "строка git fetch в makefile не найдена ровно один раз - нужен ручной разбор"
backup_file "$M"
if [ "$APPLY" = 1 ]; then
  sed -i 's#git fetch origin --quiet; \\$#git fetch origin --quiet || true; \\#' "$M"
  grep -qF -- "git fetch origin --quiet || true;" "$M" && ok "makefile исправлен. Копия: $BK/" || die "правка не применилась"
else say "(dry-run) сделал бы git fetch в makefile нефатальным"; fi
