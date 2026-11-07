#!/bin/sh
# Шаг 7. Перевод контейнеров php и service с PHP 8.1 (Alpine 3.18, снят с поддержки) на PHP 8.3 (Alpine 3.23).
# Что делает: правит dockerfile/php.dockerfile и docker-compose.yml, собирает образ, проверяет
# (версия, набор модулей не уже старого, php -l для ВСЕХ файлов бота, qrencode), потом подменяет.
# Правки лежат только на сервере (в git бота их нет) - см. README, раздел «Что затирает обновление бота».
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
cd "$BASE" || die "нет $BASE"
DF=dockerfile/php.dockerfile; DC=docker-compose.yml; NEW=mercurykd/vpnbot-php:1.7-php83; ALP=${ALP:-alpine:3.23}
if grep -q php83 "$DF" && grep -q ':1.7-php83' "$DC"; then ok "уже на PHP 8.3"; docker exec php php -v | head -1; exit 0; fi
[ "$(grep -c php81 "$DF")" -ge 1 ] || die "в $DF нет php81 - структура отличается, нужен ручной разбор"
[ "$(grep -c 'mercurykd/vpnbot-php:1.7$' "$DC")" = 2 ] || die "ожидалось ровно 2 строки образа php:1.7 в $DC"
[ "$(grep -c '/etc/php81/php.ini' "$DC")" = 2 ] || die "ожидалось ровно 2 монтирования php81/php.ini в $DC"
docker image inspect mercurykd/vpnbot-php:backup-$DATE >/dev/null 2>&1 || die "нет тега backup-$DATE. Сначала 05-backup.sh --apply"
W=/root/php83-test; mkdir -p "$W"
# 1. новый dockerfile: php81->php83, пакет qrencode (бинарь теперь в libqrencode-tools), симлинк php
sed -e 's/php81/php83/g' -e 's/libqrencode \\/libqrencode libqrencode-tools \\/' "$DF" > "$W/php.dockerfile"
grep -q libqrencode-tools "$W/php.dockerfile" || die "не нашёл строку libqrencode в dockerfile - правьте вручную"
printf '\nRUN ln -sf /usr/bin/php83 /usr/bin/php\n' >> "$W/php.dockerfile"
if [ "$APPLY" != 1 ]; then say "(dry-run) собрал бы тестовый образ из $W/php.dockerfile и проверил его; затем правки $DF и $DC, пересоздание php и service"; exit 0; fi
I=mercurykd/vpnbot-php:test-php83
docker build -q -f "$W/php.dockerfile" --build-arg image="$ALP" -t $I "$BASE/dockerfile" >/dev/null || die "сборка не удалась"
docker run --rm $I php -v | head -1 | grep -q 'PHP 8\.3' || die "в образе не PHP 8.3"
docker run --rm mercurykd/vpnbot-php:backup-$DATE php -m 2>/dev/null | sort > $W/mod.old
docker run --rm $I php -m | sort > $W/mod.new
MISS=$(comm -23 $W/mod.old $W/mod.new | grep -v '^zend_test$' | tr '\n' ' ')   # zend_test - тестовый модуль самого PHP, боту не нужен; [ -z "$MISS" ] || die "в новом образе нет модулей: $MISS"
ok "модули: ничего не потеряно"
BADL=$(docker run --rm -v "$BASE/app:/app:ro" $I sh -c 'find /app -name "*.php" -exec php -l {} \; 2>&1' | grep -v '^No syntax errors' | head)
[ -z "$BADL" ] || { say "$BADL"; die "php -l нашёл ошибки"; }
ok "php -l: все файлы бота без синтаксических ошибок"
docker run --rm $I sh -c 'echo t | qrencode -t ASCII >/dev/null' || die "qrencode не работает"
ok "qrencode работает"
# 2. боевые правки
cp -a "$DC" "$BK/docker-compose.yml"; cp -a "$DF" "$BK/php.dockerfile"
cp "$W/php.dockerfile" "$DF"
sed -i -e 's#mercurykd/vpnbot-php:1.7$#mercurykd/vpnbot-php:1.7-php83#' -e 's#/etc/php81/php.ini#/etc/php83/php.ini#' "$DC"
for n in $(grep -n 'mercurykd/vpnbot-php:1.7-php83' "$DC" | cut -d: -f1); do
  m=$((n+4)); sed -n "${m}p" "$DC" | grep -q 'image: ${IMAGE}' && sed -i "${m}s#\${IMAGE}#$ALP#" "$DC" || warn "строка $m не 'image: \${IMAGE}', проверьте build-arg вручную"
done
docker tag $I $NEW
dc config -q && ok "compose-файл валиден" || { cp -a "$BK/docker-compose.yml" "$DC"; cp -a "$BK/php.dockerfile" "$DF"; die "compose не прошёл, вернул старые файлы"; }
dc up -d --no-deps --force-recreate php service | tail -5
sleep 40; docker ps --format '{{.Names}}|{{.Status}}' | sort
docker exec php php -v | head -1
ok "готово. Откат: cp $BK/docker-compose.yml $BASE/docker-compose.yml; cp $BK/php.dockerfile $BASE/dockerfile/php.dockerfile; затем dc up -d --no-deps --force-recreate php service"
