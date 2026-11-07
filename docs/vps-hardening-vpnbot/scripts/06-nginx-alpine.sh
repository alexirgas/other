#!/bin/sh
# Шаг 6. Обновить nginx (контейнеры ng и up) пересборкой на свежем Alpine (nginx 1.24 -> 1.28+).
# Безопасность: новый образ сначала собирается под тестовым тегом, конфиг проверяется (nginx -t)
# и сравнивается со СТАРЫМ образом; только если результаты одинаковы - подмена и перезапуск ng+up.
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
ALP=${ALP:-alpine:3.23}
IMG=$(docker inspect ng --format '{{.Config.Image}}'); [ -n "$IMG" ] || die "контейнер ng не найден"
REPO=${IMG%%:*}
say "образ ng: $IMG; текущий nginx: $(docker exec ng nginx -v 2>&1)"
docker image inspect "$REPO:backup-$DATE" >/dev/null 2>&1 || die "нет $REPO:backup-$DATE. Сначала шаг 05-backup.sh --apply"
NET=$(docker inspect ng --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
if [ "$APPLY" != 1 ]; then say "(dry-run) собрал бы $REPO:test из dockerfile/nginx.dockerfile на $ALP, сравнил nginx -t со старым, подменил $IMG, пересоздал ng и up"; exit 0; fi
( cd "$BASE" && docker build -q -f dockerfile/nginx.dockerfile --build-arg image="$ALP" -t "$REPO:test" dockerfile ) >/dev/null || die "сборка не удалась"
say "новый nginx: $(docker run --rm "$REPO:test" nginx -v 2>&1)"
T() { docker run --rm --network "$NET" --tmpfs /logs --volumes-from ng:ro "$1" nginx -t 2>&1 | sed 's/nginx\/[0-9.]*//'; }
OLD=$(T "$REPO:backup-$DATE"); NEWR=$(T "$REPO:test")
[ "$OLD" = "$NEWR" ] || { say "--- старый:"; say "$OLD"; say "--- новый:"; say "$NEWR"; die "результат nginx -t отличается, подмену не делаю"; }
ok "nginx -t у старого и нового образа одинаков"
docker tag "$REPO:test" "$IMG"
dc up -d --no-deps --force-recreate ng up | tail -5
sleep 30; docker ps --format '{{.Names}}|{{.Status}}' | grep -E '^(ng|up)\|'
ok "готово. Откат: docker tag $REPO:backup-$DATE $IMG && (cd $BASE && docker compose up -d --no-deps --force-recreate ng up)  (с теми же --env-file и IP/VER)"
