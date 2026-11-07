#!/bin/sh
# Шаг 14. Не терять накопленный трафик (config/xray.stats) при перезагрузке сервера.
#
# Как это устроено в боте: каждые 60 с цикл бота (контейнер svc) пишет в xray.stats блок "session" = живые счётчики xray.
# В "global" они переносятся (collectSession) ТОЛЬКО когда сам бот перезапускает xray. При reboot xray стартует с нуля,
# бот затирает "session" новыми значениями - всё накопленное с прошлого переноса (иногда десятки ГБ) пропадает.
# Это не связано с очисткой логов: файл лежит в config/, очистка трогает только logs/.
#
# Что ставит скрипт: systemd-служба vpnbot-stats-save. Её ExecStop срабатывает при остановке системы ДО остановки Docker:
# останавливает svc (чтобы цикл бота не перезаписал файл), переносит session -> global, обнуляет session.
# Ручной запуск перед ручным "make r": sh /usr/local/sbin/vpnbot-collect-stats.sh (потом make r пересоздаст svc и xr).
#
# Режим restore: sh 14-xray-stats-guard.sh restore [--apply] - вернуть счётчики из последнего бэкапа
# /root/vpnbot-backup-*.tar.gz (старый session из бэкапа добавляется в global; один раз, есть маркер).
. "$(dirname "$0")/lib.sh"; need_root
MODE=install; [ "${1:-}" = restore ] && MODE=restore
S=/usr/local/sbin/vpnbot-collect-stats.sh; U=/etc/systemd/system/vpnbot-stats-save.service
F=$BASE/config/xray.stats
mode_banner
[ -f "$F" ] || die "нет $F"

if [ "$MODE" = install ]; then
  if [ "$APPLY" != 1 ]; then say "(dry-run) установил бы $S и службу vpnbot-stats-save (ExecStop при выключении)"; exit 0; fi
  cat > "$S" <<'COLLECT'
#!/bin/sh
# Перенос session -> global в xray.stats (идемпотентно). STATS_FILE и NO_DOCKER - для тестов.
F=${STATS_FILE:-/root/vpnbot_extra/config/xray.stats}
[ -s "$F" ] || exit 0
[ -n "$NO_DOCKER" ] || docker stop -t 5 svc >/dev/null 2>&1 || true
python3 - "$F" <<'PY'
import json, sys, os
p = sys.argv[1]
d = json.load(open(p))
def z(): return {'download': 0, 'upload': 0}
def fold(e):
    if not isinstance(e, dict): return
    g = e.setdefault('global', z()); s = e.get('session') or z()
    for k in ('download', 'upload'): g[k] = int(g.get(k, 0)) + int(s.get(k, 0))
    e['session'] = z()
def vals(x): return list(x.values()) if isinstance(x, dict) else (x or [])
fold(d)
for sec in ('users', 'users_by_id', 'inbounds'):
    for e in vals(d.get(sec)): fold(e)
tmp = p + '.tmp'; json.dump(d, open(tmp, 'w')); os.replace(tmp, p)
PY
logger -t vpnbot-stats-save "xray.stats: session -> global"
COLLECT
  chmod 755 "$S"; sh -n "$S" || die "синтаксис"
  cat > "$U" <<UNIT
[Unit]
Description=Save vpnbot xray traffic stats before shutdown
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=$S
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload && systemctl enable --now vpnbot-stats-save.service
  systemctl is-active vpnbot-stats-save.service && ok "служба активна: при выключении перенесёт session -> global"
  exit 0
fi

# ---- restore ----
M=/root/xray.stats.restored-$DATE
[ -f "$M" ] && { ok "уже восстановлено ($M)"; exit 0; }
T=$(ls -t /root/vpnbot-backup-*.tar.gz 2>/dev/null | head -1); [ -n "$T" ] || die "нет /root/vpnbot-backup-*.tar.gz"
W=$(mktemp -d); tar xzf "$T" -C "$W" --wildcards '*/config/xray.stats' 2>/dev/null; OLD=$(find "$W" -name xray.stats | head -1)
[ -s "$OLD" ] || die "в бэкапе нет xray.stats"
say "бэкап: $T"; if [ "$APPLY" != 1 ]; then say "(dry-run) добавил бы session из бэкапа в global (svc будет остановлен на секунды)"; exit 0; fi
cp -a "$F" "$BK/xray.stats.before-restore"
docker stop -t 5 svc >/dev/null 2>&1 || true
python3 - "$OLD" "$F" <<'PY'
import json, sys, os
old = json.load(open(sys.argv[1])); cur = json.load(open(sys.argv[2]))
def z(): return {'download': 0, 'upload': 0}
def add(dst, src):
    dst.setdefault('global', z()); dst.setdefault('session', z())
    for k in ('download', 'upload'):
        dst['global'][k] = int(dst['global'].get(k, 0)) + int(src.get('global', {}).get(k, 0)) + int(src.get('session', {}).get(k, 0))
add(cur, old)
for i, v in (old.get('users_by_id') or {}).items():
    if i in (cur.get('users_by_id') or {}): add(cur['users_by_id'][i], v)
ou, cu = old.get('users') or [], cur.get('users') or []
if isinstance(ou, list) and isinstance(cu, list) and len(ou) == len(cu):
    for a, b in zip(cu, ou): add(a, b)
for t, v in (old.get('inbounds') or {}).items():
    if isinstance(v, dict) and isinstance((cur.get('inbounds') or {}).get(t), dict): add(cur['inbounds'][t], v)
tmp = sys.argv[2] + '.tmp'; json.dump(cur, open(tmp, 'w')); os.replace(tmp, sys.argv[2])
PY
docker start svc >/dev/null 2>&1 || true
rm -rf "$W"; touch "$M"; ok "счётчики восстановлены из бэкапа (трафик между бэкапом и перезагрузкой восстановить нельзя)"
