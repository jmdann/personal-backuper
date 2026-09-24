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
  echo "home: $HOME"
  echo "arch: $(uname -m)"
  have sw_vers && sw_vers | sed 's/^/macos_/'
} > "$META/manifest.txt"

if have brew; then
  info "Brewfile (fórmulas, casks, taps, apps da App Store via mas, extensões do VS Code)..."
  # Versões novas do Homebrew não aceitam mais --describe.
  if brew bundle dump --force --describe --file="$META/Brewfile" >/dev/null 2>&1 \
     || brew bundle dump --force --file="$META/Brewfile" >/dev/null; then
    ok "Brewfile ($(grep -cE '^(brew|cask|mas|vscode) ' "$META/Brewfile") itens)"
  else
    warn "não consegui gerar o Brewfile; os apps não serão reinstalados automaticamente"
  fi
else
  warn "Homebrew não encontrado; pulando Brewfile"
fi

# Apps instalados fora do Homebrew que valem garantir no Mac novo.
if [ -f "$META/Brewfile" ]; then
  for pair in "1Password.app:1password" "1Password 7.app:1password@7" "Orca.app:stablyai/orca/orca"; do
    app="${pair%%:*}"; cask="${pair#*:}"
    if [ -d "/Applications/$app" ] && ! grep -q "^cask \"\(.*/\)\{0,1\}${cask##*/}\"" "$META/Brewfile"; then
      case "$cask" in */*/*) printf 'tap "%s"\n' "${cask%/*}" >> "$META/Brewfile" ;; esac
      printf 'cask "%s"\n' "$cask" >> "$META/Brewfile"
      ok "$app adicionado ao Brewfile"
    fi
  done
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

# Senhas do app Senhas / iCloud Keychain: não saem num arquivo, sincronizam pelo iCloud.
MMA="$HOME/Library/Preferences/MobileMeAccounts.plist"
if [ -f "$MMA" ] && have plutil && have python3; then
  kc="$(plutil -convert json -o - "$MMA" 2>/dev/null | python3 -c '
import json, sys
try:
    accts = json.load(sys.stdin).get("Accounts", [])
    on = any(s.get("Name") == "KEYCHAIN_SYNC" and s.get("Enabled") for a in accts for s in a.get("Services", []))
    print("on" if on else "off")
except Exception:
    print("?")' || echo '?')"
  case "$kc" in
    on)  ok "iCloud Keychain ativo: as senhas do app Senhas vão aparecer sozinhas no Mac novo" ;;
    off) warn "iCloud Keychain DESLIGADO: as senhas do app Senhas não vão para o Mac novo."
         warn "Ative em Ajustes do Sistema > [seu nome] > iCloud > Senhas (ou exporte no app Senhas)."
         confirm "Continuar mesmo assim?" || die "abortado" ;;
    *)   info "não consegui verificar o iCloud Keychain; confira em Ajustes do Sistema > [seu nome] > iCloud > Senhas" ;;
  esac
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

# Argumentos do find para pular DEV_EXCLUDES (caminhos relativos ao $HOME, como o find vê).
SKIP_ARGS=(-name node_modules)
while IFS= read -r x; do
  [ -n "$x" ] && SKIP_ARGS+=(-o -path "$x")
done <<EOF_SKIP
$(lines "$DEV_EXCLUDES")
EOF_SKIP
if [ "${#SKIP_ARGS[@]}" -gt 2 ]; then
  info "ignorando: $(lines "$DEV_EXCLUDES" | tr '\n' ' ')"
fi

cd "$HOME"
while IFS= read -r d; do
  [ -d "$d" ] || continue
  info "varrendo ~/$d"
  # Repositórios git
  find "$d" -maxdepth "$DEV_MAX_DEPTH" \( "${SKIP_ARGS[@]}" -o -name .venv -o -name vendor \) -prune \
       -o -name .git \( -type d -o -type f \) -print -prune 2>/dev/null | while IFS= read -r g; do
    repo="${g%/.git}"
    remote="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
    branch="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    printf '%s\t%s\t%s\n' "$repo" "${remote:-<sem-remote>}" "$branch" >> "$META/repos.tsv"
    probs=""
    if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null | head -1)" ]; then probs="$probs mudanças-não-commitadas"; fi
    if [ -n "$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ]; then probs="$probs commits-não-enviados"; fi
    if [ -n "$(git -C "$repo" stash list 2>/dev/null | head -1)" ]; then probs="$probs stash"; fi
    if [ -z "$remote" ]; then probs="$probs sem-remote"; fi
    if [ -n "$probs" ]; then printf '%s:%s\n' "$repo" "$probs" >> "$META/git-warnings.txt"; fi
  done
  # Arquivos .env (normalmente fora do git)
  find "$d" -maxdepth "$DEV_MAX_DEPTH" \
       \( "${SKIP_ARGS[@]}" -o -name .git -o -name .venv -o -name venv -o -name vendor -o -name .terraform \) -prune \
       -o -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name '.envrc' \) \
       ! -name '*.example' ! -name '*.sample' ! -name '*.template' -print 2>/dev/null >> "$LIST"
  # Configuração na raiz da pasta de projetos (arquivos soltos e pastas ocultas).
  if [ "$DEV_ROOT_CONFIG" = 1 ] && [ ! -e "$d/.git" ]; then
    find "$d" -mindepth 1 -maxdepth 1 \( -type f -o -type l -o \( -type d -name '.*' \) \) \
         ! -name .DS_Store ! -name .git ! -name .Trash ! -name '.localized' 2>/dev/null \
    | while IFS= read -r item; do
        kb="$(du -sk "$item" 2>/dev/null | awk '{print $1}')"
        if [ "${kb:-0}" -gt $((DEV_ROOT_MAX_MB * 1024)) ]; then
          warn "grande demais, fora do backup: ~/$item ($((kb / 1024)) MB)"
        else
          echo "$item"
        fi
      done >> "$LIST"
  fi
done <<EOF_DIRS
$(lines "$DEV_DIRS")
EOF_DIRS
cd - >/dev/null
ok "$(wc -l < "$META/repos.tsv" | tr -d ' ') repositórios, $(wc -l < "$LIST" | tr -d ' ') arquivos (.env e configs)"

if [ -s "$META/git-warnings.txt" ]; then
  warn "repositórios com trabalho que NÃO está no remote (não serão copiados, só o .env):"
  sed 's/^/      /' "$META/git-warnings.txt" >&2
  confirm "Continuar mesmo assim?" || die "abortado. Faça commit/push e rode de novo."
fi

# ---------------------------------------------------------------------------
if [ "$CHROME_PROFILES" = 1 ] && [ -d "$HOME/$CHROME_DIR" ]; then
  step "Perfis do Google Chrome"
  wait_chrome_closed
  echo "$CHROME_DIR" >> "$LIST"
  # Senhas e cookies do Chrome são criptografados com uma chave guardada no Keychain.
  # Sem levar a chave, eles não abrem no Mac novo.
  if have security; then
    info "o macOS vai pedir acesso ao item 'Chrome Safe Storage' do Keychain: digite sua senha e clique em Permitir"
    info "(se a janela não aparecer, ela pode estar atrás das outras janelas)"
    if key="$(security find-generic-password -w -s 'Chrome Safe Storage' -a 'Chrome' 2>/dev/null)"; then
      (umask 077; printf '%s' "$key" > "$META/chrome-safe-storage.key")
      ok "chave do Chrome Safe Storage"
    else
      warn "sem acesso à chave; no Mac novo senhas e cookies locais do Chrome não serão recuperados"
    fi
    unset key
  fi
  # Inventário das extensões de cada perfil (perfil, id, nome).
  if have python3; then
    python3 - "$HOME/$CHROME_DIR" > "$META/chrome-extensions.tsv" <<'PYEXT' || true
import json, os, sys
root = sys.argv[1]
def load(p):
    try:
        with open(p, encoding="utf-8-sig") as f: return json.load(f)
    except Exception: return {}
names = load(os.path.join(root, "Local State")).get("profile", {}).get("info_cache", {})
for prof in sorted(os.listdir(root)):
    ext_dir = os.path.join(root, prof, "Extensions")
    if not os.path.isdir(ext_dir): continue
    pname = names.get(prof, {}).get("name", prof)
    for eid in sorted(os.listdir(ext_dir)):
        vers = sorted(v for v in os.listdir(os.path.join(ext_dir, eid)) if not v.startswith("."))
        if not vers: continue
        base = os.path.join(ext_dir, eid, vers[-1])
        name = load(os.path.join(base, "manifest.json")).get("name", eid)
        if name.startswith("__MSG_"):
            key = name[6:-2]
            for loc in ("pt_BR", "en", "en_US"):
                msgs = {k.lower(): v for k, v in load(os.path.join(base, "_locales", loc, "messages.json")).items()}
                if key.lower() in msgs:
                    name = msgs[key.lower()].get("message", name); break
        print(f"{pname}\t{eid}\t{name}")
PYEXT
    ok "extensões: $(cut -f2 "$META/chrome-extensions.tsv" | sort -u | wc -l | tr -d ' ') (lista em chrome-extensions.tsv)"
  fi
  ok "perfis: $(find "$HOME/$CHROME_DIR" -maxdepth 2 -name Preferences -path '*/*/Preferences' | wc -l | tr -d ' ')"
fi

if [ -d "$HOME/$ORCA_DIR" ] || [ -d "$HOME/.orca" ]; then
  step "Orca"
  wait_app_closed Orca
  # Como o Chrome, o Orca (Electron) criptografa credenciais com uma chave do Keychain.
  if have security; then
    info "procurando a chave 'Orca Safe Storage' no Keychain..."
    info "(se o macOS abrir uma janela pedindo senha, ela pode estar atrás das outras janelas)"
    acct="$(security find-generic-password -s 'Orca Safe Storage' 2>/dev/null | sed -n 's/.*"acct"<blob>="\(.*\)"$/\1/p')"
    if [ -n "$acct" ]; then
      info "o macOS vai pedir acesso ao item 'Orca Safe Storage' do Keychain: digite sua senha e clique em Permitir"
      if key="$(security find-generic-password -w -s 'Orca Safe Storage' -a "$acct" 2>/dev/null)"; then
        (umask 077; printf '%s' "$key" > "$META/orca-safe-storage.key"; printf '%s' "$acct" > "$META/orca-safe-storage.acct")
        ok "chave do Orca Safe Storage"
      else
        warn "sem acesso à chave; no Mac novo talvez seja preciso reconectar integrações do Orca (Linear, Jira...)"
      fi
      unset key
    fi
  fi
  [ -n "${acct:-}" ] || info "o Orca não tem chave no Keychain (nada a levar)"
  ok "configurações do Orca"
fi

step "Segredos e dotfiles"
{ lines "$HOME_PATHS"; lines "$EXTRA_PATHS"; } | while IFS= read -r p; do
  if [ -e "$HOME/$p" ]; then echo "$p"; fi
done >> "$LIST"
sort -u -o "$LIST" "$LIST"

# Pastas do $HOME citadas nos dotfiles (ex.: `source ~/.minha-ferramenta/bin/x`) que não
# estão no backup: pergunta se deve incluir cada uma.
IGNORE_REFS=' Library Applications Desktop Documents Downloads Movies Music Pictures Public
 .cache .local .config .npm .nvm .pyenv .rbenv .rustup .cargo .bun .deno .sdkman .volta .asdf
 .oh-my-zsh .zsh .zinit .antigen .docker .orbstack .rd .colima .vscode .cursor go '
for d in $(lines "$DEV_DIRS"); do IGNORE_REFS="$IGNORE_REFS ${d%%/*} "; done
REFS="$(while IFS= read -r p; do
          f="$HOME/$p"
          case "$p" in Library/*|*/.env*|*.env) continue ;; esac
          if ! [ -f "$f" ] || ! grep -Iq . "$f" 2>/dev/null; then continue; fi
          HOME_RE="$HOME" perl -ne 'while (m{(?:\$HOME|\$\{HOME\}|~|\Q$ENV{HOME_RE}\E)/([A-Za-z0-9._-]+)}g) { print "$1\n" }' "$f"
        done < "$LIST" | sort -u)"
for r in $REFS; do
  case "$IGNORE_REFS" in *" $r "*) continue ;; esac
  [ -e "$HOME/$r" ] || continue
  grep -qxF "$r" "$LIST" && continue
  grep -q "^$r/" "$LIST" && continue
  kb="$(du -sk "$HOME/$r" 2>/dev/null | awk '{print $1}')"
  if [ "${kb:-0}" -gt 1048576 ]; then
    warn "A pasta ~/$r é citada nos seus dotfiles, mas tem $((kb / 1048576)) GB: grande demais para este backup."
    warn "Se for uma pasta de projetos, adicione '$r' em DEV_DIRS no config.sh (os repositórios"
    warn "são re-clonados e os .env copiados). Se não, copie-a por disco externo."
    continue
  fi
  if confirm "Seus dotfiles usam ~/$r ($(du -sh "$HOME/$r" 2>/dev/null | awk '{print $1}')), que não está no backup. Incluir?"; then
    echo "$r" >> "$LIST"
  else
    info "para sempre incluir, adicione '$r' em EXTRA_PATHS no config.sh"
  fi
done
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
