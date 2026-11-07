#!/bin/sh
# Шаг 8. Исправление ложной ошибки «проверка VLESS-ключа не проходит» в меню бота.
# Причина: в скрипте проверки awk с RS="\r\n\r\n" не находит ответ после tr -d '\r' -> всегда пусто.
# Правка 1 строки в app/traits/UserPortalTrait.php. Работает только если строка найдена ровно 1 раз.
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
P=$BASE/app/traits/UserPortalTrait.php; [ -f "$P" ] || die "нет $P"
python3 - "$P" "$APPLY" "$BK" <<'PY' || exit 1
import sys, shutil, os, subprocess
p, apply, bk = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
old = r'''  | tr -d '\r' | awk 'BEGIN{RS="\r\n\r\n"} NR==1{next} {print; exit}')'''
new = r'''  | tr -d '\r' | awk 'NF{l=$0} END{print l}')'''
s = open(p, encoding="utf-8", errors="surrogateescape").read()
if new in s and old not in s: print("[ OK ] уже исправлено"); sys.exit(0)
if s.count(old) != 1: print("[FAIL] ожидалась ровно 1 старая строка, найдено", s.count(old), "- структура другая, нужен ручной разбор"); sys.exit(1)
if not apply: print("(dry-run) заменил бы 1 строку awk в", p); sys.exit(0)
shutil.copy2(p, os.path.join(bk, "UserPortalTrait.php.orig"))
open(p, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old, new))
r = subprocess.run(["docker","exec","php","php","-l","/app/traits/UserPortalTrait.php"], capture_output=True, text=True)
print((r.stdout + r.stderr).strip())
if r.returncode: shutil.copy2(os.path.join(bk, "UserPortalTrait.php.orig"), p); print("[FAIL] lint не прошёл, вернул оригинал"); sys.exit(1)
print("[ OK ] исправлено. Копия:", bk)
PY
[ "$APPLY" = 1 ] && say "Проверьте в боте: меню -> vless -> пользователь -> проверка ключа."
