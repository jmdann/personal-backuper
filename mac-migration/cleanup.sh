#!/usr/bin/env bash
# Apaga o backup (e o .sha256) do bucket/diretório depois da restauração.
# Uso: ./cleanup.sh [s3://.../arquivo.age | gs://... | /caminho/arquivo.age]
#      (padrão: backup mais recente na pasta mac-migration do iCloud Drive)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

URL="${1:-}"
if [ -z "$URL" ]; then
  URL="$(latest_backup_in "$MIGRATION_DEST")" || die "nenhum backup em $MIGRATION_DEST"
fi
confirm "Apagar $URL e $URL.sha256 permanentemente?" || exit 1
remote_rm "$URL"
remote_rm "$URL.sha256" || true
ok "removido"
