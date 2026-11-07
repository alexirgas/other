#!/bin/sh
# Шаг 1. Вход по SSH только по ключу (пароль выключен). Порт НЕ меняем.
# Страховка: без рабочего ключа в authorized_keys скрипт отказывается работать,
# иначе вы закроете себе дверь.
. "$(dirname "$0")/lib.sh"; need_root; mode_banner
AK=/root/.ssh/authorized_keys
[ -s "$AK" ] && grep -qE '^(ssh-(ed25519|rsa)|ecdsa-)' "$AK" || die "в $AK нет ключа. Сначала добавьте ключ (см. README, шаг 1) и проверьте вход по нему в НОВОМ окне."
F=/etc/ssh/sshd_config.d/20-hardening.conf
NEW='PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30'
if [ -f "$F" ] && [ "$(cat "$F")" = "$NEW" ]; then ok "$F уже настроен"; else
  backup_file "$F"
  if [ "$APPLY" = 1 ]; then printf '%s\n' "$NEW" > "$F"; chmod 644 "$F"; sshd -t || { rm -f "$F"; die "sshd -t не прошёл, файл удалён"; }; systemctl reload ssh 2>/dev/null || systemctl reload sshd; ok "применено, sshd перечитал конфиг"
  else say "(dry-run) записал бы $F:"; printf '%s\n' "$NEW" | sed 's/^/    /'; fi
fi
if [ "$APPLY" = 1 ]; then
  pa=$(sshd -T | awk '$1=="passwordauthentication"{print $2}')
  [ "$pa" = no ] && ok "sshd -T: passwordauthentication no" || die "другой файл в sshd_config.d перебивает настройку (passwordauthentication=$pa). Посмотрите: grep -ri PasswordAuthentication /etc/ssh/"
  say "ВАЖНО: НЕ закрывайте текущее окно. Откройте новое и проверьте вход по ключу."
fi
