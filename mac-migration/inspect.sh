#!/usr/bin/env bash
# Mostra o conteúdo de um backup sem restaurar nada. Seguro para rodar em qualquer Mac.
# Uso: ./inspect.sh [arquivo.age | s3://... | gs://... | https://...]
#      (padrão: backup mais recente na pasta mac-migration do iCloud Drive)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

SRC="${1:-}"
if [ -z "$SRC" ]; then
  SRC="$(latest_backup_in "$MIGRATION_DEST")" || die "nenhum backup em $MIGRATION_DEST"
fi
have age || die "'age' não encontrado (brew install age)"

WORK="$(make_workdir)"
trap 'rm -rf "$WORK"' EXIT

step "Abrindo $(basename "$SRC") (digite a senha)"
remote_get "$SRC" "$WORK/b.age"
age -d "$WORK/b.age" | tar -C "$WORK" -xzf -
BUNDLE="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'mac-migration-*' | head -1)"
META="$BUNDLE/meta"
sed 's/^/    /' "$META/manifest.txt"

step "Arquivos de ~ incluídos ($(du -h "$BUNDLE/home.tar" | awk '{print $1}'))"
sed 's/^/    ~\//' "$META/files.txt"

step "Inventário"
count() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
info "Brewfile:            $(grep -cE '^(brew|cask|mas|vscode) ' "$META/Brewfile" 2>/dev/null || echo 0) itens"
info "Apps em /Applications: $(count "$META/applications.txt")"
info "Extensões VS Code:   $(count "$META/vscode-extensions.txt")"
info "Extensões Cursor:    $(count "$META/cursor-extensions.txt")"
info "npm global:          $(count "$META/npm-global.txt")"
info "pipx / uv / cargo:   $(count "$META/pipx.txt") / $(count "$META/uv-tools.txt") / $(count "$META/cargo.txt")"
info "Repositórios git:    $(count "$META/repos.tsv")"
info "Crontab:             $([ -s "$META/crontab.txt" ] && echo sim || echo não)"
info "Chaves GPG:          $([ -f "$META/gpg-secret-keys.asc" ] && echo sim || echo não)"
info "Chave do Chrome:     $([ -f "$META/chrome-safe-storage.key" ] && echo sim || echo não)"
info "Chave do Orca:       $([ -f "$META/orca-safe-storage.key" ] && echo sim || echo não)"
if [ -s "$META/chrome-extensions.tsv" ]; then
  step "Extensões do Chrome"
  awk -F'\t' '{ printf "    %-20s %s\n", $1, $3 }' "$META/chrome-extensions.tsv"
fi
if [ -s "$META/git-warnings.txt" ]; then
  warn "repositórios com trabalho fora do remote:"
  sed 's/^/      /' "$META/git-warnings.txt" >&2
fi
ok "nada foi alterado neste computador"
