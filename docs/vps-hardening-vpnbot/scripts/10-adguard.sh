#!/bin/sh
# Шаг 10. Обновить AdGuard Home (контейнер ad) до актуального релиза. Образ собирается с --pull,
# версия берётся из бинарника и пишется в тег (например 1.4-v0.107.80), compose указывает на него.
# Перед этим обязателен шаг 05 (копия AdGuardHome.yaml и тома). AdGuard сам мигрирует схему
# конфига при старте - поэтому копия обязательна. Перезапускается ТОЛЬКО ad.
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
cd "$BASE" || die "нет $BASE"; DC=docker-compose.yml
N=$(grep -n 'image: mercurykd/vpnbot-ad:1.4$' "$DC" | cut -d: -f1)
if [ -z "$N" ]; then ok "строка 'vpnbot-ad:1.4' не найдена - возможно уже обновлено:"; grep -n 'vpnbot-ad' "$DC"; exit 0; fi
[ "$(echo "$N" | wc -w)" = 1 ] || die "строка образа ad не уникальна: $N"
[ -f "/root/ad-backup-$DATE/AdGuardHome.yaml" ] || die "нет /root/ad-backup-$DATE. Сначала 05-backup.sh --apply"
say "сейчас: $(docker exec ad /opt/adguardhome/AdGuardHome --version)"
[ "$APPLY" = 1 ] || { say "(dry-run) собрал бы свежий образ, сверил версию и конфиг, пересоздал ad"; exit 0; }
I=mercurykd/vpnbot-ad:test-new
docker build -q --pull -f dockerfile/adguard.dockerfile -t $I dockerfile >/dev/null || die "сборка не удалась"
V=$(docker run --rm --entrypoint /opt/adguardhome/AdGuardHome $I --version | grep -oE 'v[0-9.]+' | head -1)
[ -n "$V" ] || die "не удалось узнать версию нового образа"
say "новая версия: $V"
T=$(mktemp -d); cp config/AdGuardHome.yaml "$T/c.yaml"
docker run --rm --entrypoint /opt/adguardhome/AdGuardHome -v "$T:/t" $I --check-config -c /t/c.yaml -w /t >/dev/null 2>&1 \
  && ok "конфиг принят новой версией" || { rm -rf "$T"; die "новая версия не приняла конфиг, ничего не менял"; }
rm -rf "$T"
TAG=1.4-$V; cp -a "$DC" "$BK/docker-compose.yml"
docker tag $I mercurykd/vpnbot-ad:$TAG
sed -i "${N}s#vpnbot-ad:1.4\$#vpnbot-ad:$TAG#" "$DC"
dc config -q || { cp -a "$BK/docker-compose.yml" "$DC"; die "compose не прошёл, вернул файл"; }
dc up -d --no-deps --force-recreate ad | tail -3; sleep 20
docker ps --format '{{.Names}}|{{.Status}}|{{.Image}}' | grep '^ad|'
docker exec php nslookup example.com 10.10.0.5 2>&1 | tail -3
ok "готово. Откат: cp $BK/docker-compose.yml $BASE/$DC; cp /root/ad-backup-$DATE/AdGuardHome.yaml $BASE/config/; dc up -d --no-deps --force-recreate ad"
