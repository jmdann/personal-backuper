#!/usr/bin/env bash
# Faz o git escolher sozinho a conta do GitHub (logada no `gh`) pela organização do
# repositório, conforme GITHUB_ACCOUNTS no config.sh. Pode rodar quantas vezes quiser.
#
# Uso: ./github-accounts.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

have gh || die "GitHub CLI não encontrado (brew install gh)"
have git || die "git não encontrado"

GIT_DIR_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/git"
MAP="$GIT_DIR_CFG/github-accounts"
HELPER="$GIT_DIR_CFG/gh-account-credential"
mkdir -p "$GIT_DIR_CFG"

step "Contas do GitHub por organização"
lines "$GITHUB_ACCOUNTS" > "$MAP"
sed 's/^/    /' "$MAP"

cat > "$HELPER" <<'HELPER_EOF'
#!/bin/sh
# Credential helper do git: entrega o token do `gh` da conta ligada à organização do
# repositório (arquivo github-accounts: "<organização> <usuário>", "*" = padrão).
[ "$1" = get ] || exit 0
host=; path=
while IFS= read -r line; do
  [ -z "$line" ] && break
  case "$line" in
    host=*) host=${line#host=} ;;
    path=*) path=${line#path=} ;;
  esac
done
[ "$host" = github.com ] || exit 0
owner=$(printf '%s' "${path%%/*}" | tr '[:upper:]' '[:lower:]')
map="${XDG_CONFIG_HOME:-$HOME/.config}/git/github-accounts"
[ -f "$map" ] || exit 0
user=$(awk -v o="$owner" 'tolower($1) == o { print $2; exit }' "$map")
[ -n "$user" ] || user=$(awk '$1 == "*" { print $2; exit }' "$map")
[ -n "$user" ] || exit 0
gh=$(command -v gh 2>/dev/null)
for c in /opt/homebrew/bin/gh /usr/local/bin/gh; do [ -n "$gh" ] || { [ -x "$c" ] && gh=$c; }; done
[ -n "$gh" ] || exit 0
token=$("$gh" auth token --hostname github.com --user "$user" 2>/dev/null) || exit 0
[ -n "$token" ] || exit 0
printf 'username=%s\npassword=%s\n' "$user" "$token"
HELPER_EOF
chmod +x "$HELPER"

# Só para github.com: manda o caminho do repositório ao helper e ignora outros helpers
# (como o Keychain, que guarda uma única conta).
git config --global credential.https://github.com.useHttpPath true
git config --global --unset-all credential.https://github.com.helper 2>/dev/null || true
git config --global --add credential.https://github.com.helper ''
git config --global --add credential.https://github.com.helper "$HELPER"
ok "git configurado ($HELPER)"

step "Verificando logins no gh"
awk '{ print $2 }' "$MAP" | sort -u | while IFS= read -r u; do
  if gh auth token --hostname github.com --user "$u" >/dev/null 2>&1; then
    ok "$u"
  else
    warn "$u não está logado no gh: rode 'gh auth login' e entre com essa conta"
  fi
done
