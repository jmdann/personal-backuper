# shellcheck shell=bash disable=SC2034
# Configuração da migração. Edite à vontade antes de rodar backup.sh.
# Todos os caminhos são relativos ao $HOME. Caminhos inexistentes são ignorados.

# Destino padrão do backup: uma pasta no iCloud Drive. Pode ser sobrescrito por
# argumento ou variável de ambiente com:
#   s3://meu-bucket/mac-migration   (AWS S3, ou R2/MinIO via AWS_ENDPOINT_URL)
#   gs://meu-bucket/mac-migration   (Google Cloud Storage)
#   /Volumes/HD-Externo/migracao    (diretório local / disco externo)
ICLOUD_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
MIGRATION_DEST="${MIGRATION_DEST:-$ICLOUD_DIR/mac-migration}"

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
.claude-switch
.orca
.config/orca
Library/Application Support/Orca
Library/Application Support/orca
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

# Google Chrome: leva todos os perfis (favoritos, extensões, histórico, abas,
# configurações, senhas e cookies locais) sem os caches. Use 0 para desligar.
CHROME_PROFILES="${CHROME_PROFILES:-1}"
CHROME_DIR='Library/Application Support/Google/Chrome'

# Extensões que o restore garante instalar pela Chrome Web Store, mesmo que a cópia
# do perfil falhe (formato: <id> <comentário>). O Chrome pede para ativar cada uma
# em cada perfil. O id aparece na URL da extensão na Chrome Web Store.
CHROME_ESSENTIAL_EXTENSIONS='
aeblfdkhhhdcdjpifhhbdiojplfjncoa 1Password
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
node_modules
.venv
__pycache__
.next
.turbo
.pnpm-store
DerivedData
Google/Chrome/*/Cache
Google/Chrome/*/Code Cache
Google/Chrome/*/GPUCache
Google/Chrome/*/DawnGraphiteCache
Google/Chrome/*/DawnWebGPUCache
Google/Chrome/*/Service Worker/CacheStorage
Google/Chrome/*/Service Worker/ScriptCache
Google/Chrome/*/File System
Google/Chrome/*/blob_storage
Google/Chrome/Crashpad
Google/Chrome/GrShaderCache
Google/Chrome/GraphiteDawnCache
Google/Chrome/ShaderCache
Google/Chrome/component_crx_cache
Google/Chrome/extensions_crx_cache
Google/Chrome/OptimizationGuidePredictionModels
Google/Chrome/Safe Browsing
Google/Chrome/Snapshots
Google/Chrome/SingletonLock
Google/Chrome/SingletonSocket
Google/Chrome/SingletonCookie
'

# Diretórios onde ficam seus projetos. Neles o backup:
#   - coleta arquivos .env* (que normalmente não estão no git)
#   - lista os repositórios git (caminho + remote) para re-clonar no Mac novo
#   - avisa sobre mudanças não commitadas / commits não enviados
DEV_DIRS='
orca
orca/workspaces/LettrLabs.AiHarness
code
dev
projects
src
workspace
repos
Developer
Documents/GitHub
'

# Pastas dentro de DEV_DIRS que ficam totalmente de fora (nem repositórios, nem .env).
DEV_EXCLUDES='
orca/glue
orca/workspaces
orca/ando
orca/ando1
orca/happy-widget
orca/happyCaseStudy
orca/test-thomsonreuters
orca/AgentGrade
'

# Leva também os arquivos soltos e as pastas ocultas na raiz de cada DEV_DIR que não
# é um repositório (ex.: ~/orca/.env, ~/orca/orca.json, ~/orca/.claude). Itens acima de
# DEV_ROOT_MAX_MB ficam de fora com aviso. Use 0 para desligar.
DEV_ROOT_CONFIG="${DEV_ROOT_CONFIG:-1}"
DEV_ROOT_MAX_MB="${DEV_ROOT_MAX_MB:-100}"

# Profundidade máxima de busca dentro de DEV_DIRS.
DEV_MAX_DEPTH="${DEV_MAX_DEPTH:-5}"

# Domínios de `defaults` exportados (só são importados com restore.sh --import-defaults).
DEFAULTS_DOMAINS='
com.apple.dock
com.apple.finder
com.apple.AppleMultitouchTrackpad
com.apple.screencapture
'
