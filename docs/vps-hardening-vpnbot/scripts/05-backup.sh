#!/bin/sh
# Шаг 5. Резервные копии ПЕРЕД любыми изменениями бота:
#  - архив папки бота (конфиги, ключи, сертификаты) -> /root/vpnbot-backup-ДАТА.tar.gz
#  - тег :backup-ДАТА на каждый используемый образ (для отката за минуту)
#  - копия AdGuardHome.yaml и тома AdGuard
# Архив содержит СЕКРЕТЫ: хранить только у себя, в публичный репозиторий не класть.
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
[ -d "$BASE" ] || die "нет папки $BASE"
T=/root/vpnbot-backup-$DATE.tar.gz
do_it "tar -> $T" sh -c "tar czf '$T' -C '$(dirname "$BASE")' '$(basename "$BASE")' && chmod 600 '$T'"
for img in $(docker ps --format '{{.Image}}' | grep '^mercurykd/vpnbot-' | sort -u); do
  repo=${img%%:*}
  do_it "docker tag $img $repo:backup-$DATE" docker tag "$img" "$repo:backup-$DATE"
done
A=/root/ad-backup-$DATE
if docker inspect ad >/dev/null 2>&1; then
  V=$(docker inspect ad --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Source}}{{end}}{{end}}')
  do_it "копия AdGuard в $A" sh -c "mkdir -p '$A' && chmod 700 '$A' && cp -a '$BASE/config/AdGuardHome.yaml' '$A/' && { [ -z '$V' ] || tar czf '$A/adguard-work-volume.tar.gz' -C '$V' .; } && chmod 600 '$A'/*"
fi
[ "$APPLY" = 1 ] && { ls -la "$T"; say "Скачайте архив на свой компьютер: scp -P <порт> root@<IP>:$T ."; }
