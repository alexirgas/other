#!/bin/sh
# Шаг 17. Освободить диск от мусора Docker: кэш сборки и образы, которыми не пользуется ни один контейнер.
#
# Что чистится:
#   1) Кэш сборки (docker builder prune -af). После сборок бота (make r, xray.dockerfile) его набирается 1+ ГБ.
#      Минус: следующая пересборка пойдёт с нуля и займёт дольше (для замены ядра xray всё равно используется --no-cache).
#   2) Образы, которые не используются ни одним контейнером (в том числе остановленным): старые версии после обновлений, тестовые теги.
# Что НЕ трогается:
#   - образы работающих и остановленных контейнеров;
#   - образы с тегом backup-* (их делает шаг 05 для отката на случай неудачного обновления). Удалить и их: ALL=1 sh 17-docker-cleanup.sh --apply
#   - тома (volumes), контейнеры, сети.
# Безопасно запускать повторно. В пробном режиме (без --apply) показывает, что именно было бы удалено.
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
command -v docker >/dev/null 2>&1 || die "docker не найден"
say "--- до: место, занятое Docker"; docker system df
say "--- диск /: $(df -h / | awk 'NR==2{print $3" занято из "$2" ("$5")"}')"
used=$(docker ps -aq | xargs -r docker inspect --format '{{.Image}}' | sort -u)
say "--- образы без контейнеров:"
docker images --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' | while read -r id name; do
  echo "$used" | grep -qx "$id" && continue
  case "$name" in *:backup-*) if [ "${ALL:-0}" != 1 ]; then say "оставлен (откат): $name"; continue; fi;; esac
  t=$name; [ "$name" = "<none>:<none>" ] && t=$id
  if [ "$APPLY" = 1 ]; then
    if docker rmi "$t" >/dev/null 2>&1; then say "удалён: $name"; else warn "не удалось удалить: $name"; fi
  else say "(dry-run) удалил бы образ: $name"; fi
done
do_it "очистка кэша сборки (docker builder prune -af)" docker builder prune -af >/dev/null
if [ "$APPLY" = 1 ]; then
  say "--- после:"; docker system df; say "диск /: $(df -h / | awk 'NR==2{print $3" занято из "$2" ("$5")"}')"
  say "контейнеры:"; docker ps --format '{{.Names}} {{.Status}}'
fi
