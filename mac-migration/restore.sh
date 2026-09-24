#!/usr/bin/env bash
# Roda no Mac NOVO. Baixa o backup, descriptografa, restaura segredos/dotfiles
# e reinstala apps e ferramentas.
#
# Uso: ./restore.sh [origem] [opções]
#   origem: s3://... | gs://... | https://... (URL pré-assinada) | /caminho/arquivo.age
#           (padrão: backup mais recente na pasta mac-migration do iCloud Drive)
# Opções:
#   --skip-brew        não roda `brew bundle`
#   --clone-repos      re-clona os repositórios git nos mesmos caminhos
#   --import-defaults  importa preferências do Dock/Finder/Trackpad
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

SRC=""; SKIP_BREW=0; CLONE_REPOS=0; IMPORT_DEFAULTS=0
for arg in "$@"; do
  case "$arg" in
    --skip-brew) SKIP_BREW=1 ;;
    --clone-repos) CLONE_REPOS=1 ;;
    --import-defaults) IMPORT_DEFAULTS=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) die "opção desconhecida: $arg" ;;
    *) SRC="$arg" ;;
  esac
done
if [ -z "$SRC" ]; then
  SRC="$(latest_backup_in "$MIGRATION_DEST")" \
    || die "nenhum backup em $MIGRATION_DEST. Se usou o iCloud Drive, abra-o no Finder e espere sincronizar."
  info "usando o backup mais recente: $(basename "$SRC")"
fi
KIND="$(dest_kind "$SRC")"
[ "$KIND" != unknown ] || die "origem inválida: $SRC"

WORK="$(make_workdir)"
trap 'rm -rf "$WORK"' EXIT
TS="$(date +%Y%m%d-%H%M%S)"
PREV="$HOME/.migration-previous-$TS"

# ---------------------------------------------------------------------------
step "Pré-requisitos"
if [ "$(uname)" = Darwin ]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    info "instalando Xcode Command Line Tools (conclua a janela que vai abrir)..."
    xcode-select --install || true
    until xcode-select -p >/dev/null 2>&1; do sleep 10; done
  fi
  if ! have brew; then
    info "instalando Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && break
  done
fi
need() { have "$1" || { have brew || die "'$1' não encontrado"; brew install "${2:-$1}"; }; }
need age
[ "$KIND" = s3 ] && need aws awscli
[ "$KIND" = gs ] && { have gcloud || brew install --cask google-cloud-sdk; }
ok "ok"

# ---------------------------------------------------------------------------
step "Baixando backup"
ENC="$WORK/backup.tar.gz.age"
remote_get "$SRC" "$ENC"
GOT="$(sha256_of "$ENC")"
case "$KIND" in
  s3|gs|file)
    if remote_get "${SRC}.sha256" "$WORK/expected.sha256" 2>/dev/null; then
      [ "$GOT" = "$(tr -d '[:space:]' < "$WORK/expected.sha256")" ] || die "sha256 não confere! arquivo corrompido ou adulterado"
      ok "sha256 confere"
    else
      warn "arquivo .sha256 não encontrado; sha256 = $GOT"
    fi ;;
  http) info "sha256 = $GOT  (compare com o valor impresso pelo backup.sh)"
        confirm "O sha256 confere?" || die "abortado" ;;
esac

# ---------------------------------------------------------------------------
step "Descriptografando (digite a senha usada no backup)"
age -d "$ENC" | tar -C "$WORK" -xzf -
rm -f "$ENC"
BUNDLE="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'mac-migration-*' | head -1)"
[ -n "$BUNDLE" ] || die "conteúdo inesperado no backup"
META="$BUNDLE/meta"
sed 's/^/    /' "$META/manifest.txt"

# ---------------------------------------------------------------------------
if grep -qxF 'Library/Application Support/Google/Chrome' "$META/files.txt"; then
  step "Google Chrome"
  wait_chrome_closed
  if [ -f "$META/chrome-safe-storage.key" ] && have security; then
    security delete-generic-password -s 'Chrome Safe Storage' -a 'Chrome' >/dev/null 2>&1 || true
    if security add-generic-password -s 'Chrome Safe Storage' -a 'Chrome' \
         -w "$(cat "$META/chrome-safe-storage.key")" -T '/Applications/Google Chrome.app'; then
      ok "chave do Chrome Safe Storage no Keychain"
    else
      warn "não consegui gravar a chave; senhas/cookies locais do Chrome não vão abrir"
    fi
  fi
fi

step "Restaurando segredos e dotfiles em $HOME"
tar -tf "$BUNDLE/home.tar" | while IFS= read -r f; do
  case "$f" in */) continue ;; esac
  if [ -f "$HOME/$f" ] || [ -L "$HOME/$f" ]; then
    mkdir -p "$PREV/$(dirname "$f")"
    cp -p "$HOME/$f" "$PREV/$f"
  fi
done
[ -d "$PREV" ] && warn "arquivos já existentes foram copiados para $PREV antes de sobrescrever"
tar -C "$HOME" -xpf "$BUNDLE/home.tar"
ok "$(wc -l < "$META/files.txt" | tr -d ' ') itens restaurados"

info "ajustando permissões"
if [ -d "$HOME/.ssh" ]; then
  chmod 700 "$HOME/.ssh"
  find "$HOME/.ssh" -type d -exec chmod 700 {} +
  find "$HOME/.ssh" -type f -exec chmod 600 {} +
  find "$HOME/.ssh" -type f -name '*.pub' -exec chmod 644 {} +
fi
for p in .aws .azure .kube .config/gh .config/gcloud .docker; do
  [ -d "$HOME/$p" ] && chmod -R go-rwx "$HOME/$p"
done
for p in .netrc .npmrc .pypirc .gem/credentials .cargo/credentials.toml .terraform.d/credentials.tfrc.json; do
  [ -f "$HOME/$p" ] && chmod 600 "$HOME/$p"
done
ok "permissões"

# ---------------------------------------------------------------------------
if [ -f "$META/gpg-secret-keys.asc" ]; then
  step "Importando chaves GPG"
  need gpg gnupg
  gpg --batch --import "$META/gpg-public-keys.asc" 2>/dev/null || true
  gpg --import "$META/gpg-secret-keys.asc"
  gpg --import-ownertrust < "$META/gpg-ownertrust.txt"
  ok "chaves GPG"
fi

# ---------------------------------------------------------------------------
if [ "$SKIP_BREW" = 0 ] && [ -f "$META/Brewfile" ] && have brew; then
  step "Instalando apps e ferramentas (brew bundle) — pode demorar"
  grep -q '^mas ' "$META/Brewfile" && info "apps da App Store exigem login na App Store antes"
  brew bundle install --file="$META/Brewfile" || warn "alguns itens do Brewfile falharam; veja acima"
  cp "$META/Brewfile" "$HOME/Brewfile.migrated"
fi

step "Ferramentas de linguagem"
install_list() { # <arquivo> <comando...>
  local file="$1"; shift
  [ -s "$file" ] || return 0
  have "$1" || { warn "$1 não instalado; pulando $(basename "$file")"; return 0; }
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if "$@" "$pkg" >/dev/null 2>&1; then info "✓ $pkg"; else warn "falhou: $pkg"; fi
  done < "$file"
  return 0
}
install_list "$META/vscode-extensions.txt" code --install-extension
install_list "$META/cursor-extensions.txt" cursor --install-extension
install_list "$META/npm-global.txt" npm install -g
install_list "$META/pipx.txt" pipx install
install_list "$META/uv-tools.txt" uv tool install
install_list "$META/cargo.txt" cargo install

# ---------------------------------------------------------------------------
if [ "$IMPORT_DEFAULTS" = 1 ] && [ -d "$META/defaults" ] && have defaults; then
  step "Preferências do macOS"
  for f in "$META"/defaults/*.plist; do
    [ -f "$f" ] || continue
    d="$(basename "$f" .plist)"
    defaults import "$d" "$f" && info "✓ $d"
  done
  killall Dock Finder 2>/dev/null || true
fi

if [ -s "$META/crontab.txt" ]; then
  step "Crontab"
  sed 's/^/    /' "$META/crontab.txt"
  if confirm "Instalar este crontab?"; then crontab "$META/crontab.txt" && ok "crontab"; fi
fi

# ---------------------------------------------------------------------------
if [ -s "$META/repos.tsv" ]; then
  cp "$META/repos.tsv" "$HOME/repos.migrated.tsv"
  if [ "$CLONE_REPOS" = 1 ]; then
    step "Clonando repositórios"
    while IFS="$(printf '\t')" read -r path remote; do
      [ "$remote" = "<sem-remote>" ] && { warn "sem remote: ~/$path"; continue; }
      if [ -d "$HOME/$path/.git" ]; then info "já existe: ~/$path"; continue; fi
      # O diretório pode já existir contendo só os .env restaurados.
      tmp="$HOME/$path.clone-$TS"
      if git clone -q "$remote" "$tmp" </dev/null; then
        if [ -d "$HOME/$path" ]; then
          tar -C "$HOME/$path" -cf - . | tar -C "$tmp" -xpf -
          rm -rf "${HOME:?}/$path"
        fi
        mkdir -p "$(dirname "$HOME/$path")"
        mv "$tmp" "$HOME/$path"
        info "✓ ~/$path"
      else
        rm -rf "$tmp"; warn "falhou: $remote"
      fi
    done < "$META/repos.tsv"
  else
    info "lista de repositórios salva em ~/repos.migrated.tsv (use --clone-repos para clonar)"
  fi
fi

if [ -s "$META/git-warnings.txt" ]; then
  warn "no Mac antigo estes repositórios tinham trabalho fora do remote:"
  sed 's/^/      /' "$META/git-warnings.txt" >&2
fi

step "Pronto"
cat <<MSG
Próximos passos manuais:
  - ssh-add --apple-use-keychain ~/.ssh/<sua-chave>   (e teste: ssh -T git@github.com)
  - Abra um novo terminal para carregar os dotfiles
  - Confira apps fora do Homebrew e faça login neles: ~/applications.migrated.txt
  - Apague o backup do bucket:  ./cleanup.sh <url-s3/gs-do-backup>
MSG
cp "$META/applications.txt" "$HOME/applications.migrated.txt" 2>/dev/null || true
