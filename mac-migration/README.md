# Migração de Mac

Scripts para levar ambiente de desenvolvimento, segredos e apps de um Mac para outro.
Os segredos saem **criptografados no seu Mac** (com [`age`](https://github.com/FiloSottile/age) e uma senha)
antes de irem para o bucket. O bucket só vê um blob opaco.

| Script | Onde roda | O que faz |
| --- | --- | --- |
| `backup.sh` | Mac antigo | coleta → criptografa → envia para o bucket |
| `restore.sh` | Mac novo | baixa → confere sha256 → descriptografa → restaura → reinstala |
| `cleanup.sh` | qualquer um | apaga o backup do bucket |
| `config.sh` | — | lista do que entra no backup (edite à vontade) |

## O que é migrado

- **Segredos:** `~/.ssh`, `~/.aws`, `~/.kube`, `~/.docker/config.json`, `~/.netrc`, `~/.npmrc`, `~/.pypirc`,
  gcloud, Azure, `gh`, Terraform, Cargo, Gem, Maven/Gradle, chaves **GPG** (exportadas + ownertrust).
- **Arquivos `.env`** de todos os projetos em `~/code`, `~/dev`, `~/projects`, `~/src`, `~/Developer`… (`.env.example` e afins são ignorados).
- **Dotfiles:** zsh/bash/fish, oh-my-zsh custom, p10k, starship, git, vim/nvim, tmux, terminais, Claude Code, settings do VS Code/Cursor.
- **Inventário para reinstalar:** `Brewfile` (fórmulas, casks, taps, App Store via `mas`, extensões VS Code),
  extensões VS Code/Cursor, pacotes globais npm/pipx/uv/cargo, crontab, preferências do Dock/Finder/Trackpad.
- **Repositórios git:** lista caminho + remote para re-clonar no mesmo lugar (`--clone-repos`).
  O backup **avisa** sobre repositórios com mudanças não commitadas, commits não enviados ou stash e pede confirmação.

### O que NÃO é migrado (faça à parte)

- **Keychain / senhas:** use iCloud Keychain ou seu gerenciador de senhas.
- **Documentos, fotos, arquivos grandes:** iCloud Drive, Assistente de Migração ou disco externo.
- **Licenças de apps e 2FA:** confira manualmente (`~/applications.migrated.txt` lista todos os apps do Mac antigo).

## 1. Preparar o bucket (uma vez)

Bucket **privado**, com criptografia e expiração automática — mesmo que você esqueça do `cleanup.sh`, o backup some.

**AWS S3**
```sh
BUCKET=meu-mac-migration-$RANDOM
aws s3api create-bucket --bucket $BUCKET --region us-east-1
aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-lifecycle-configuration --bucket $BUCKET --lifecycle-configuration \
  '{"Rules":[{"ID":"expira","Status":"Enabled","Filter":{},"Expiration":{"Days":14}}]}'
```
(Cloudflare R2 / MinIO também funcionam: exporte `AWS_ENDPOINT_URL=...`.)

**Google Cloud Storage**
```sh
BUCKET=meu-mac-migration-$RANDOM
gcloud storage buckets create gs://$BUCKET --location=southamerica-east1 \
  --uniform-bucket-level-access --public-access-prevention
echo '{"rule":[{"action":{"type":"Delete"},"condition":{"age":14}}]}' > /tmp/lc.json
gcloud storage buckets update gs://$BUCKET --lifecycle-file=/tmp/lc.json
```

## 2. No Mac antigo

```sh
git clone <este-repo> && cd <este-repo>/mac-migration
# (opcional) edite config.sh: EXTRA_PATHS, DEV_DIRS...
./backup.sh s3://$BUCKET/mac-migration      # ou gs://$BUCKET/mac-migration, ou /Volumes/Disco/migracao
```

O script pede uma **senha de criptografia** — guarde-a no gerenciador de senhas; sem ela não há restauração.
No fim ele imprime o comando exato para rodar no Mac novo e, no S3, uma **URL pré-assinada** (válida por 7 dias)
que dispensa configurar credenciais AWS no Mac novo — resolvendo o problema do ovo e da galinha
(as credenciais da AWS estão *dentro* do backup).

## 3. No Mac novo

```sh
git clone <este-repo> && cd <este-repo>/mac-migration   # o git vem com as Command Line Tools
./restore.sh 'https://...url-pre-assinada...'            # ou s3://... / gs://... / arquivo local
```

Opções:

- `--clone-repos` — re-clona todos os repositórios nos mesmos caminhos (os `.env` restaurados são preservados).
- `--import-defaults` — importa preferências do Dock, Finder, Trackpad e screenshots.
- `--skip-brew` — pula o `brew bundle` (útil para rodar de novo só a parte de segredos).

O restore instala Xcode CLT e Homebrew se faltarem, confere o sha256, faz cópia de qualquer arquivo que
seria sobrescrito em `~/.migration-previous-<data>/`, corrige permissões (`~/.ssh` 700/600 etc.), importa as
chaves GPG, roda o `Brewfile` e reinstala extensões e pacotes globais. Os arquivos temporários
descriptografados ficam num diretório `mktemp` com permissão 700 e são apagados ao final.

## 4. Limpeza

```sh
./cleanup.sh s3://$BUCKET/mac-migration/mac-migration-<host>-<data>.tar.gz.age
```

Depois de conferir que está tudo certo no Mac novo, apague o bucket inteiro se ele era só para isso.
Se algum segredo pode ter vazado no caminho, rotacione-o (chaves AWS, tokens do GitHub etc.).
