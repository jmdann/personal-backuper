# Migração de Mac

Scripts para levar ambiente de desenvolvimento, segredos e apps de um Mac para outro.
Os segredos saem **criptografados no seu Mac** (com [`age`](https://github.com/FiloSottile/age) e uma senha)
antes de irem para o **iCloud Drive** (padrão), um disco externo ou um bucket S3/GCS — o destino só vê um blob opaco.

| Script | Onde roda | O que faz |
| --- | --- | --- |
| `backup.sh` | Mac antigo | coleta → criptografa → salva no iCloud Drive (ou outro destino) |
| `restore.sh` | Mac novo | baixa → confere sha256 → descriptografa → restaura → reinstala |
| `inspect.sh` | qualquer um | abre o backup e lista o conteúdo, sem alterar nada |
| `cleanup.sh` | qualquer um | apaga o backup do iCloud/bucket |
| `config.sh` | — | lista do que entra no backup (edite à vontade) |

## O que é migrado

- **Segredos:** `~/.ssh`, `~/.aws`, `~/.kube`, `~/.docker/config.json`, `~/.netrc`, `~/.npmrc`, `~/.pypirc`,
  gcloud, Azure, `gh`, Terraform, Cargo, Gem, Maven/Gradle, chaves **GPG** (exportadas + ownertrust).
- **Arquivos `.env`** de todos os projetos em `~/code`, `~/dev`, `~/projects`, `~/src`, `~/Developer`… (`.env.example` e afins são ignorados).
- **Dotfiles:** zsh/bash/fish, oh-my-zsh custom, p10k, starship, git, vim/nvim, tmux, terminais, Claude Code, settings do VS Code/Cursor.
- **Inventário para reinstalar:** `Brewfile` (fórmulas, casks, taps, App Store via `mas`, extensões VS Code),
  extensões VS Code/Cursor, pacotes globais npm/pipx/uv/cargo, crontab, preferências do Dock/Finder/Trackpad.
- **Google Chrome:** todos os perfis (favoritos, extensões e seus dados, histórico, abas, configurações), sem os caches.
  Também leva a chave `Chrome Safe Storage` do Keychain, para que **senhas e cookies salvos localmente** abram no Mac novo.
  O macOS pede sua senha para liberar essa chave no backup. Os dois scripts pedem para fechar o Chrome (Cmd+Q) antes.
  Para desligar: `CHROME_PROFILES=0 ./backup.sh`.
- **Extensões do Chrome:** vão com os perfis. Além disso, as de `CHROME_ESSENTIAL_EXTENSIONS` no `config.sh`
  (por padrão o **1Password**) são instaladas pela Chrome Web Store no Mac novo mesmo se a cópia do perfil falhar;
  o Chrome pede para ativá-las. A lista completa, com links, fica em `~/chrome-extensions.migrated.tsv`.
- **App do 1Password:** se estiver em `/Applications` mas não veio do Homebrew, entra no `Brewfile` mesmo assim.
- **App Senhas / iCloud Keychain:** não vai no arquivo; sincroniza pelo iCloud. O backup verifica se a
  sincronização está ativa e avisa se não estiver.
- **Repositórios git:** lista caminho + remote para re-clonar no mesmo lugar (`--clone-repos`).
  O backup **avisa** sobre repositórios com mudanças não commitadas, commits não enviados ou stash e pede confirmação.

### O que NÃO é migrado (faça à parte)

- **Keychain / senhas:** vêm pelo iCloud Keychain (ative "Senhas" no iCloud dos dois Macs); a única exceção é a chave do Chrome, citada acima.
- **Cofres do 1Password:** ficam na nuvem da 1Password. No Mac novo, entre com e-mail, senha e **Secret Key**
  (está no Emergency Kit) — tenha-a em mãos antes de formatar o Mac antigo.
- **Chrome:** alguns sites (principalmente Google) podem pedir login de novo, porque amarram a sessão ao
  aparelho. Se você usa a sincronização do Chrome com a conta Google, ela continua sendo a garantia principal.
- **Documentos, fotos, arquivos grandes:** iCloud Drive, Assistente de Migração ou disco externo.
- **Licenças de apps e 2FA:** confira manualmente (`~/applications.migrated.txt` lista todos os apps do Mac antigo).

## Passo a passo (iCloud Drive — padrão)

Requisito: **mesmo Apple ID** nos dois Macs, com **iCloud Drive ativado**
(Ajustes do Sistema › [seu nome] › iCloud › iCloud Drive) e espaço livre no iCloud para o backup
(normalmente poucos MB; o `backup.sh` mostra o tamanho).

**1. No Mac antigo**

```sh
git clone <este-repo> && cd <este-repo>/mac-migration
# (opcional) edite config.sh: EXTRA_PATHS, DEV_DIRS...
./backup.sh
```

- O script pede uma **senha de criptografia**. Guarde-a no gerenciador de senhas: sem ela não há restauração.
- O arquivo vai para `iCloud Drive/mac-migration/`. O iCloud envia em segundo plano: **antes de apagar ou
  formatar o Mac antigo**, confira no Finder que o arquivo não mostra mais o ícone de upload.

**2. No Mac novo**

```sh
git clone <este-repo> && cd <este-repo>/mac-migration   # o git vem com as Command Line Tools
./restore.sh
```

Sem argumentos, ele pega o backup mais recente da pasta do iCloud. Se o arquivo ainda estiver só na nuvem,
o script pede o download ao iCloud e espera. Se a pasta ainda não apareceu, abra o iCloud Drive no Finder
e aguarde a sincronização.

Opções:

- `--clone-repos` — re-clona todos os repositórios nos mesmos caminhos (os `.env` restaurados são preservados).
- `--import-defaults` — importa preferências do Dock, Finder, Trackpad e screenshots.
- `--skip-brew` — pula o `brew bundle` (útil para rodar de novo só a parte de segredos).

O restore instala Xcode CLT e Homebrew se faltarem, confere o sha256, faz cópia de qualquer arquivo que
seria sobrescrito em `~/.migration-previous-<data>/`, corrige permissões (`~/.ssh` 700/600 etc.), importa as
chaves GPG, roda o `Brewfile` e reinstala extensões e pacotes globais. Os arquivos temporários
descriptografados ficam num diretório `mktemp` com permissão 700 e são apagados ao final.

**3. Limpeza**

```sh
./cleanup.sh     # apaga o backup mais recente do iCloud (pede confirmação)
```

Se algum segredo pode ter vazado no caminho, rotacione-o (chaves AWS, tokens do GitHub etc.).

## Outros destinos

Passe o destino como argumento para o `backup.sh` e o caminho/URL do arquivo para `restore.sh`/`cleanup.sh`:

- **Disco externo:** `./backup.sh /Volumes/MeuHD/migracao`
- **AWS S3** (ou R2/MinIO com `AWS_ENDPOINT_URL`): `./backup.sh s3://$BUCKET/mac-migration`.
  Além do caminho, o script imprime uma **URL pré-assinada** (7 dias) que dispensa credenciais AWS no Mac novo.
- **Google Cloud Storage:** `./backup.sh gs://$BUCKET/mac-migration`

Para S3/GCS, use um bucket privado com expiração automática:

```sh
# S3
aws s3api create-bucket --bucket $BUCKET --region us-east-1
aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-lifecycle-configuration --bucket $BUCKET --lifecycle-configuration \
  '{"Rules":[{"ID":"expira","Status":"Enabled","Filter":{},"Expiration":{"Days":14}}]}'

# GCS
gcloud storage buckets create gs://$BUCKET --location=southamerica-east1 \
  --uniform-bucket-level-access --public-access-prevention
echo '{"rule":[{"action":{"type":"Delete"},"condition":{"age":14}}]}' > /tmp/lc.json
gcloud storage buckets update gs://$BUCKET --lifecycle-file=/tmp/lc.json
```
