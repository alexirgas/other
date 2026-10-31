#!/bin/sh
# Самооткат замены config.yaml (OpenWrt + Mihomo/SSClash).
# Запуск:  setsid sh /tmp/cfg-rollback.sh <ИМЯ_БЭКАПА> [СЕКУНД] >/dev/null 2>&1 </dev/null &
# Пока файл-маркер /tmp/cfg_rollback существует, по истечении таймера
# конфиг вернётся из бэкапа и перезагрузится через API.
# Удалили маркер (rm /tmp/cfg_rollback) - откат отменён, скрипт сам выйдет за <=10 с.
BAKNAME="$1"; TOTAL="${2:-600}"
[ -n "$BAKNAME" ] || { echo "usage: $0 <backup-file-name> [seconds]"; exit 2; }
CFG=/opt/clash/config.yaml
BAK=/opt/clash/$BAKNAME
MARK=/tmp/cfg_rollback
LOG=/tmp/cfg_rollback.log
PIDF=/tmp/cfg_rollback.pid

echo $$ > "$PIDF"
i=0; N=$((TOTAL / 10))
while [ "$i" -lt "$N" ]; do
  [ -f "$MARK" ] || { echo "$(date): маркер снят, откат не нужен" >> "$LOG"; rm -f "$PIDF"; exit 0; }
  sleep 10; i=$((i + 1))
done
[ -f "$MARK" ] || { echo "$(date): маркер снят, откат не нужен" >> "$LOG"; rm -f "$PIDF"; exit 0; }

[ -s "$BAK" ] || { echo "$(date): ОШИБКА: нет $BAK" >> "$LOG"; exit 1; }
cp -p "$BAK" "$CFG.rollback" && mv -f "$CFG.rollback" "$CFG" \
  || { echo "$(date): ОШИБКА: не удалось вернуть бэкап" >> "$LOG"; exit 1; }

# Если у API есть секрет - положите его в /root/.mihomo_secret (chmod 600)
if [ -s /root/.mihomo_secret ]; then
  AUTH="Authorization: Bearer $(tr -d '\r\n' < /root/.mihomo_secret)"
else
  AUTH="X-No-Auth: 1"
fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X PUT -H "$AUTH" \
  -H "Content-Type: application/json" -d '{"path":"/opt/clash/config.yaml"}' \
  "http://127.0.0.1:9090/configs?force=true")
echo "$(date): ОТКАТ выполнен, API HTTP $code" >> "$LOG"
logger -t cfg_rollback "rollback executed, API HTTP $code"
rm -f "$MARK" "$PIDF"
