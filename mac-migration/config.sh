# shellcheck shell=bash disable=SC2034
# Configuração da migração. Edite à vontade antes de rodar backup.sh.
# Todos os caminhos são relativos ao $HOME. Caminhos inexistentes são ignorados.

# Destino padrão do backup (pode ser sobrescrito por argumento/variável de ambiente):
#   s3://meu-bucket/mac-migration   (AWS S3, ou R2/MinIO via AWS_ENDPOINT_URL)
#   gs://meu-bucket/mac-migration   (Google Cloud Storage)
#   /Volumes/HD-Externo/migracao    (diretório local / disco externo)
MIGRATION_DEST="${MIGRATION_DEST:-}"

# Validade (segundos) da URL pré-assinada gerada para S3. Máximo de 7 dias (604800).
PRESIGN_EXPIRES="${PRESIGN_EXPIRES:-604800}"

# Segredos, credenciais e dotfiles.
HOME_PATHS='
.ssh
.aws
.azure
.kube
.docker/config.json
.netrc
.npmrc
.yarnrc.yml
.pypirc
.gem/credentials
.cargo/credentials.toml
.m2/settings.xml
.gradle/gradle.properties
.terraformrc
.terraform.d/credentials.tfrc.json
.config/gcloud
.config/gh
.config/git
.gitconfig
.gitconfig.local
.gitignore_global
.zshrc
.zprofile
.zshenv
.zsh_history
.bashrc
.bash_profile
.profile
.p10k.zsh
.oh-my-zsh/custom
.config/fish
.config/starship.toml
.config/nvim
.vimrc
.tmux.conf
.config/alacritty
.config/kitty
.config/ghostty
.wezterm.lua
.claude/settings.json
.claude/CLAUDE.md
.claude/commands
.claude/agents
.claude/skills
Library/Application Support/Code/User/settings.json
Library/Application Support/Code/User/keybindings.json
Library/Application Support/Code/User/snippets
Library/Application Support/Cursor/User/settings.json
Library/Application Support/Cursor/User/keybindings.json
Library/Application Support/Cursor/User/snippets
'

# Adicione aqui qualquer outro arquivo/diretório (relativo ao $HOME), um por linha.
EXTRA_PATHS='
'

# Padrões excluídos do arquivo (sockets, caches, logs).
EXCLUDES='
*.sock
.ssh/sockets
.ssh/cm-*
.config/gcloud/logs
.config/gcloud/virtenv
.aws/cli/cache
.aws/sso/cache
.kube/cache
.kube/http-cache
.DS_Store
'

# Diretórios onde ficam seus projetos. Neles o backup:
#   - coleta arquivos .env* (que normalmente não estão no git)
#   - lista os repositórios git (caminho + remote) para re-clonar no Mac novo
#   - avisa sobre mudanças não commitadas / commits não enviados
DEV_DIRS='
code
dev
projects
src
workspace
repos
Developer
Documents/GitHub
'

# Profundidade máxima de busca dentro de DEV_DIRS.
DEV_MAX_DEPTH="${DEV_MAX_DEPTH:-5}"

# Domínios de `defaults` exportados (só são importados com restore.sh --import-defaults).
DEFAULTS_DOMAINS='
com.apple.dock
com.apple.finder
com.apple.AppleMultitouchTrackpad
com.apple.screencapture
'
