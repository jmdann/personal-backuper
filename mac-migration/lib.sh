# shellcheck shell=bash
# Funções compartilhadas. Compatível com o bash 3.2 que vem no macOS.

if [ -t 1 ]; then
  C_BLUE=$'\033[1;34m'; C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_OFF=$'\033[0m'
else
  C_BLUE=''; C_YEL=''; C_RED=''; C_GRN=''; C_OFF=''
fi

step() { printf '\n%s==> %s%s\n' "$C_BLUE" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s    ✓ %s%s\n' "$C_GRN" "$*" "$C_OFF"; }
warn() { printf '%s    ! %s%s\n' "$C_YEL" "$*" "$C_OFF" >&2; }
die()  { printf '%sERRO: %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  local answer
  printf '%s [s/N] ' "$1"
  read -r answer </dev/tty || return 1
  case "$answer" in s|S|y|Y|sim|yes) return 0 ;; *) return 1 ;; esac
}

# Imprime as linhas não vazias de uma lista multilinha (sem espaços nas pontas).
lines() {
  printf '%s\n' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true
}

sha256_of() {
  if have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

dest_kind() {
  case "$1" in
    s3://*) echo s3 ;;
    gs://*) echo gs ;;
    https://*|http://*) echo http ;;
    file://*) echo file ;;
    /*|./*|../*) echo file ;;
    *) echo unknown ;;
  esac
}

strip_file_scheme() { printf '%s' "${1#file://}"; }

# remote_put <arquivo-local> <destino/prefixo>  -> imprime a URL final do objeto
remote_put() {
  local src="$1" dest="${2%/}" name
  name="$(basename "$src")"
  case "$(dest_kind "$dest")" in
    s3)
      have aws || die "aws cli não encontrado (brew install awscli)"
      aws s3 cp --only-show-errors --sse AES256 "$src" "$dest/$name" >&2 ;;
    gs)
      have gcloud || die "gcloud não encontrado (brew install --cask google-cloud-sdk)"
      gcloud storage cp "$src" "$dest/$name" >&2 ;;
    file)
      local dir; dir="$(strip_file_scheme "$dest")"
      mkdir -p "$dir" && cp "$src" "$dir/$name" ;;
    *) die "destino não suportado: $dest" ;;
  esac
  printf '%s/%s\n' "$dest" "$name"
}

# remote_get <url-do-objeto> <arquivo-local>
remote_get() {
  local src="$1" out="$2"
  case "$(dest_kind "$src")" in
    s3)   have aws || die "aws cli não encontrado"; aws s3 cp --only-show-errors "$src" "$out" ;;
    gs)   have gcloud || die "gcloud não encontrado"; gcloud storage cp "$src" "$out" ;;
    http) curl -fL --progress-bar -o "$out" "$src" ;;
    file) cp "$(strip_file_scheme "$src")" "$out" ;;
    *) die "origem não suportada: $src" ;;
  esac
}

# remote_rm <url-do-objeto>
remote_rm() {
  case "$(dest_kind "$1")" in
    s3)   aws s3 rm "$1" ;;
    gs)   gcloud storage rm "$1" ;;
    file) rm -f "$(strip_file_scheme "$1")" ;;
    *) die "não sei apagar: $1" ;;
  esac
}

make_workdir() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/mac-migration.XXXXXX")"
  chmod 700 "$d"
  printf '%s' "$d"
}
