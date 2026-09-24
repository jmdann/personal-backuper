#!/usr/bin/env bash
# Roda no Mac ANTIGO. Coleta segredos, dotfiles e inventário de apps/ferramentas,
# criptografa tudo com `age` (senha) e envia para um bucket (S3/GCS) ou diretório.
#
# Uso: ./backup.sh [destino]
#   destino: s3://bucket/prefixo | gs://bucket/prefixo | /caminho/local
#            (padrão: pasta mac-migration no iCloud Drive, veja config.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

DEST="${1:-$MIGRATION_DEST}"
[ -n "$DEST" ] || die "informe o destino: ./backup.sh s3://meu-bucket/mac-migration"
[ "$(dest_kind "$DEST")" != unknown ] && [ "$(dest_kind "$DEST")" != http ] || die "destino inválido: $DEST"

HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="mac-migration-${HOST}-${STAMP}"

WORK="$(make_workdir)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$NAME"
META="$STAGE/meta"
mkdir -p "$META"

# ---------------------------------------------------------------------------
step "Pré-requisitos"
if ! have age; then
  have brew || die "'age' não encontrado e Homebrew ausente. Instale: https://github.com/FiloSottile/age"
  info "instalando age via Homebrew..."
  brew install age
fi
case "$(dest_kind "$DEST")" in
  s3) have aws || die "aws cli não encontrado (brew install awscli)"
      aws sts get-caller-identity >/dev/null || die "aws cli sem credenciais válidas" ;;
  gs) have gcloud || die "gcloud não encontrado (brew install --cask google-cloud-sdk)" ;;
esac
case "$DEST" in
  "$ICLOUD_DIR"*) [ -d "$ICLOUD_DIR" ] || die "iCloud Drive não encontrado. Ative em Ajustes do Sistema > [seu nome] > iCloud > iCloud Drive." ;;
esac
ok "ok (destino: $DEST)"

# ---------------------------------------------------------------------------
step "Inventário do sistema"
{
  echo "created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host: $HOST"
  echo "user: $(id -un)"
  echo "arch: $(uname -m)"
  have sw_vers && sw_vers | sed 's/^/macos_/'
} > "$META/manifest.txt"

if have brew; then
  info "Brewfile (fórmulas, casks, taps, apps da App Store via mas, extensões do VS Code)..."
  brew bundle dump --force --describe --file="$META/Brewfile" >/dev/null && ok "Brewfile"
else
  warn "Homebrew não encontrado; pulando Brewfile"
fi

ls -1 /Applications > "$META/applications.txt" 2>/dev/null || true
ls -1 "$HOME/Applications" >> "$META/applications.txt" 2>/dev/null || true
ok "lista de /Applications (para conferir apps instalados fora do Homebrew)"

have code   && code --list-extensions   > "$META/vscode-extensions.txt" 2>/dev/null && ok "extensões VS Code"
have cursor && cursor --list-extensions > "$META/cursor-extensions.txt" 2>/dev/null && ok "extensões Cursor"
if have npm; then
  npm ls -g --depth=0 --parseable 2>/dev/null | sed -e 1d -e 's#.*/node_modules/##' \
    | grep -v -x -e npm -e corepack > "$META/npm-global.txt" || true
  ok "pacotes npm globais"
fi
have pipx  && pipx list --short > "$META/pipx.txt" 2>/dev/null && ok "pacotes pipx"
have cargo && cargo install --list 2>/dev/null | awk '/^[^ ]/{print $1}' > "$META/cargo.txt" && ok "pacotes cargo"
have uv    && uv tool list 2>/dev/null | awk '/^[^ -]/{print $1}' > "$META/uv-tools.txt" && ok "ferramentas uv"
if crontab -l > "$META/crontab.txt" 2>/dev/null; then ok "crontab"; else rm -f "$META/crontab.txt"; fi

if have defaults; then
  mkdir -p "$META/defaults"
  for d in $(lines "$DEFAULTS_DOMAINS"); do
    defaults export "$d" "$META/defaults/$d.plist" 2>/dev/null || true
  done
  ok "preferências do macOS (defaults)"
fi

# ---------------------------------------------------------------------------
step "Chaves GPG"
if have gpg && gpg --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
  info "o gpg pode pedir a senha de cada chave privada"
  gpg --export-secret-keys --armor > "$META/gpg-secret-keys.asc"
  gpg --export --armor > "$META/gpg-public-keys.asc"
  gpg --export-ownertrust > "$META/gpg-ownertrust.txt"
  ok "chaves GPG exportadas"
else
  info "nenhuma chave GPG privada encontrada"
fi

# ---------------------------------------------------------------------------
step "Projetos: repositórios git e arquivos .env"
LIST="$WORK/paths.txt"
: > "$LIST"
: > "$META/repos.tsv"
: > "$META/git-warnings.txt"

cd "$HOME"
while IFS= read -r d; do
  [ -d "$d" ] || continue
  info "varrendo ~/$d"
  # Repositórios git
  find "$d" -maxdepth "$DEV_MAX_DEPTH" \( -name node_modules -o -name .venv -o -name vendor \) -prune \
       -o -type d -name .git -print -prune 2>/dev/null | while IFS= read -r g; do
    repo="${g%/.git}"
    remote="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
    printf '%s\t%s\n' "$repo" "${remote:-<sem-remote>}" >> "$META/repos.tsv"
    probs=""
    if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null | head -1)" ]; then probs="$probs mudanças-não-commitadas"; fi
    if [ -n "$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ]; then probs="$probs commits-não-enviados"; fi
    if [ -n "$(git -C "$repo" stash list 2>/dev/null | head -1)" ]; then probs="$probs stash"; fi
    if [ -z "$remote" ]; then probs="$probs sem-remote"; fi
    if [ -n "$probs" ]; then printf '%s:%s\n' "$repo" "$probs" >> "$META/git-warnings.txt"; fi
  done
  # Arquivos .env (normalmente fora do git)
  find "$d" -maxdepth "$DEV_MAX_DEPTH" \
       \( -name node_modules -o -name .git -o -name .venv -o -name venv -o -name vendor -o -name .terraform \) -prune \
       -o -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name '.envrc' \) \
       ! -name '*.example' ! -name '*.sample' ! -name '*.template' -print 2>/dev/null >> "$LIST"
done <<EOF_DIRS
$(lines "$DEV_DIRS")
EOF_DIRS
cd - >/dev/null
ok "$(wc -l < "$META/repos.tsv" | tr -d ' ') repositórios, $(wc -l < "$LIST" | tr -d ' ') arquivos .env"

if [ -s "$META/git-warnings.txt" ]; then
  warn "repositórios com trabalho que NÃO está no remote (não serão copiados, só o .env):"
  sed 's/^/      /' "$META/git-warnings.txt" >&2
  confirm "Continuar mesmo assim?" || die "abortado. Faça commit/push e rode de novo."
fi

# ---------------------------------------------------------------------------
step "Segredos e dotfiles"
{ lines "$HOME_PATHS"; lines "$EXTRA_PATHS"; } | while IFS= read -r p; do
  if [ -e "$HOME/$p" ]; then echo "$p"; fi
done >> "$LIST"
sort -u -o "$LIST" "$LIST"
cp "$LIST" "$META/files.txt"
sed 's/^/      ~\//' "$LIST"

EXC="$WORK/excludes.txt"
lines "$EXCLUDES" > "$EXC"
tar -C "$HOME" -X "$EXC" -cf "$STAGE/home.tar" -T "$LIST"
ok "home.tar ($(du -h "$STAGE/home.tar" | awk '{print $1}'))"

# ---------------------------------------------------------------------------
step "Criptografando (age, senha)"
info "escolha uma senha forte e guarde-a (ex.: no gerenciador de senhas). Sem ela não há restauração."
OUT="$WORK/$NAME.tar.gz.age"
tar -C "$WORK" -czf - "$NAME" | age -p -o "$OUT"
sha256_of "$OUT" > "$OUT.sha256"
ok "$(basename "$OUT") ($(du -h "$OUT" | awk '{print $1}'))"

# ---------------------------------------------------------------------------
step "Enviando para $DEST"
URL="$(remote_put "$OUT" "$DEST")"
remote_put "$OUT.sha256" "$DEST" >/dev/null
ok "$URL"

step "Pronto"
case "$DEST" in
  "$ICLOUD_DIR"*)
    warn "o iCloud envia o arquivo em segundo plano. Antes de apagar/formatar este Mac, confira no"
    warn "Finder (iCloud Drive > mac-migration) que o arquivo não mostra mais o ícone de upload."
    echo
    echo "No Mac NOVO (com o mesmo Apple ID e iCloud Drive ativo), clone este repositório e rode:"
    echo
    echo "    ./restore.sh" ;;
  *)
    echo "No Mac NOVO, clone este repositório e rode:"
    echo
    echo "    ./restore.sh $URL" ;;
esac
if [ "$(dest_kind "$DEST")" = s3 ]; then
  if PRESIGNED="$(aws s3 presign "$URL" --expires-in "$PRESIGN_EXPIRES" 2>/dev/null)"; then
    echo
    echo "Ou, sem precisar configurar credenciais AWS no Mac novo (URL válida por $((PRESIGN_EXPIRES / 3600))h):"
    echo
    echo "    ./restore.sh '$PRESIGNED'"
    echo
    echo "    sha256 esperado: $(cat "$OUT.sha256")"
  fi
fi
echo
case "$DEST" in
  "$ICLOUD_DIR"*) echo "Depois de restaurar, apague o backup do iCloud:  ./cleanup.sh" ;;
  *) echo "Depois de restaurar, apague o backup:  ./cleanup.sh $URL" ;;
esac
