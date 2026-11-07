#!/bin/sh
# Шаг 9. Починка «знаков вопроса» в боте (испорченная кодировка в app/bot.php форка):
#  а) иконки уведомлений в меню IP (колокольчик / без звука / запрет),
#  б) два текста: «Доступ к торрентам …» и «Обмен между пользователями …».
# Каждая правка делается только если шаблон найден РОВНО один раз. После правки - php -l.
# Остальные «????» в русских комментариях кода безвредны и не трогаются.
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
P=$BASE/app/bot.php; [ -f "$P" ] || die "нет $P"
python3 - "$P" "$APPLY" "$BK" <<'PY' || exit 1
import sys, re, shutil, os, subprocess
p, apply, bk = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
assert "Доступ".encode("utf-8") == b"\xd0\x94\xd0\xbe\xd1\x81\xd1\x82\xd1\x83\xd0\xbf", "кодировка скрипта не UTF-8"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
pat = re.compile(r"(switch \(\$pac\['silence'\]\) \{\s*case 0:\s*return )'\?\?';(\s*case 1:\s*return )'\?\?';(\s*case 2:\s*return )'\?\?';")
old1 = "'?????? ? ????????? ' . ($c[$this->getInstanceWG(1) . 'blocktorrent'] ? '????????????' : '?????????????')"
new1 = "'Доступ к торрентам ' . ($c[$this->getInstanceWG(1) . 'blocktorrent'] ? 'заблокирован' : 'разблокирован')"
old2 = "'????? ????? ?????????????? ' . ($c[$this->getInstanceWG(1) . 'exchange'] ? '????????????' : '?????????????')"
new2 = "'Обмен между пользователями ' . ($c[$this->getInstanceWG(1) . 'exchange'] ? 'заблокирован' : 'разблокирован')"
out, todo = s, []
n = len(pat.findall(s))
if n == 1:
    out = pat.sub(lambda m: m.group(1) + r'"\u{1F514}";' + m.group(2) + r'"\u{1F515}";' + m.group(3) + r'"\u{1F6AB}";', out, count=1); todo.append("иконки уведомлений")
elif n == 0: print("[ OK ] иконки: шаблон не найден (уже исправлено или другая версия)")
else: print("[FAIL] иконки: найдено", n, "мест"); sys.exit(1)
for name, o, nw in (("текст про торренты", old1, new1), ("текст про обмен", old2, new2)):
    c = out.count(o)
    if c == 1: out = out.replace(o, nw); todo.append(name)
    elif c == 0: print("[ OK ]", name + ": шаблон не найден (уже исправлено или другая версия)")
    else: print("[FAIL]", name, ": найдено", c); sys.exit(1)
if not todo: sys.exit(0)
if not apply: print("(dry-run) исправил бы:", ", ".join(todo)); sys.exit(0)
shutil.copy2(p, os.path.join(bk, "bot.php.orig"))
open(p, "w", encoding="utf-8", errors="surrogateescape").write(out)
r = subprocess.run(["docker","exec","php","php","-l","/app/bot.php"], capture_output=True, text=True)
print((r.stdout + r.stderr).strip())
if r.returncode: shutil.copy2(os.path.join(bk, "bot.php.orig"), p); print("[FAIL] lint не прошёл, вернул оригинал"); sys.exit(1)
print("[ OK ] исправлено:", ", ".join(todo), "| копия:", bk)
PY
