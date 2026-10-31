#!/bin/sh
# Безопасная замена config.yaml на роутере. Запускать НА РОУТЕРЕ.
# Перед запуском положите новый конфиг в /opt/clash/config.yaml.new
# и cfg-rollback.sh в /tmp/cfg-rollback.sh.
# Скрипт НЕ снимает маркер отката - это делаете вы вручную после проверок.
set -e
D=/opt/clash
[ -s $D/config.yaml.new ] || { echo "нет $D/config.yaml.new"; exit 1; }

# 1. Бэкап (если имя занято - добавляем b, c, ...)
BAK=config.yaml.bak-$(date +%Y%m%d)
for s in "" b c d e f; do [ -e "$D/$BAK$s" ] || { BAK="$BAK$s"; break; }; done
cp -p $D/config.yaml "$D/$BAK"
echo "бэкап: $D/$BAK"

# 2. Проверка нового конфига ядром
$D/bin/clash -d $D -t -f $D/config.yaml.new || { echo "ПРОВЕРКА НЕ ПРОЙДЕНА, ничего не менял"; exit 1; }

# 3. Взвести самооткат (10 минут), независимо от ssh-сессии
touch /tmp/cfg_rollback
setsid sh /tmp/cfg-rollback.sh "$BAK" 600 >/dev/null 2>&1 </dev/null &
sleep 2
echo "таймер взведён, PID $(cat /tmp/cfg_rollback.pid)"

# 4. Подмена и перезагрузка конфига через API (без рестарта службы)
mv -f $D/config.yaml.new $D/config.yaml
if [ -s /root/.mihomo_secret ]; then AUTH="Authorization: Bearer $(tr -d '\r\n' < /root/.mihomo_secret)"; else AUTH="X-No-Auth: 1"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X PUT -H "$AUTH" \
  -H "Content-Type: application/json" -d "{\"path\":\"$D/config.yaml\"}" \
  "http://127.0.0.1:9090/configs?force=true")
echo "API HTTP $code (ожидаем 204)"
echo "Теперь проверьте роутер. Всё хорошо -> rm /tmp/cfg_rollback ; плохо -> ничего не делайте, откат сам через 10 минут."
