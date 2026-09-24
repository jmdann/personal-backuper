#!/usr/bin/env bash
# Apaga o backup (e o .sha256) do bucket/diretório depois da restauração.
# Uso: ./cleanup.sh <s3://.../arquivo.age | gs://... | /caminho/arquivo.age>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

URL="${1:-}"
[ -n "$URL" ] || die "uso: ./cleanup.sh <url-do-backup>"
confirm "Apagar $URL e $URL.sha256 permanentemente?" || exit 1
remote_rm "$URL"
remote_rm "$URL.sha256" || true
ok "removido"
