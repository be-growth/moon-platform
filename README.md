# moon-platform

Config compartilhada do [moon](https://moonrepo.dev) da plataforma BeGrowth (CI/CD v3): o contrato de tasks, os presets por linguagem, o SAST baseline e o fragmento de workspace. Os repos de app **não copiam** estes arquivos: estendem por URL, na tag major (`v1`) ou numa versão exata.

> O repo é público de propósito. O conteúdo é só definição de task, sem segredo, e o `extends` do moon não tem como autenticar sem pôr credencial em arquivo versionado (ver "Por que público").

## Como um repo usa

`.moon/workspace.yml`:

```yaml
extends: 'https://raw.githubusercontent.com/be-growth/moon-platform/v1/workspace.yml'

projects:
  globs: ['services/*', 'libs/*', '!**/*.md']
  sources:
    repo: '.'   # todo repo precisa de um projeto na raiz: o baseline vive nele
```

Um stub em `.moon/tasks/` por arquivo da plataforma que o repo usa. Cada um tem só o `extends`; quem decide quais projetos herdam é o `inheritedBy` do arquivo remoto:

```yaml
# .moon/tasks/platform-all.yml
extends: 'https://raw.githubusercontent.com/be-growth/moon-platform/v1/tasks/all.yml'
```

`all.yml` e `baseline.yml` são obrigatórios. Os outros entram conforme o repo: `deployable.yml` se tem imagem, e o preset da linguagem.

| Arquivo | Herdado por | Conteúdo |
|---|---|---|
| `workspace.yml` | o `.moon/workspace.yml` do app | `vcs` (git, GitHub, `main`), hooks locais (`pre-commit`: `format-check` + `lint` do staged e `lib-deps`; `commit-msg`: Conventional Commits) e `pipeline.installDependencies: false` |
| `tasks/all.yml` | todo projeto | Tasks do contrato em `noop` + `implicitInputs` + a interna `sources` |
| `tasks/baseline.yml` | só o projeto na raiz | `secrets-scan` (gitleaks) e `deps-scan` (`trivy fs`). Não sobrescreva. E `lib-deps`: escreve `<serviço>/.lib-deps` com o hash das libs de cada `deployable`, para o release-please versionar o serviço quando só a lib muda (exige `jq`) |
| `tasks/deployable.yml` | tag `deployable` | Marcador `package`: quem vira imagem |
| `tasks/go.yml` | tag `go` | gofmt, `go vet`, `go build`, `go test` |
| `tasks/python-uv.yml` | tag `python-uv` | ruff, mypy, pytest, `uv build` |
| `tasks/node-pnpm.yml` | tag `node-pnpm` | `pnpm install` + scripts do `package.json` |
| `tasks/rust-cargo.yml` | tag `rust-cargo` | `cargo fmt --check`, clippy `-D warnings`, `cargo check`, `cargo test`, `cargo build`, todas depois de `rust-toolchain` (`rustup toolchain install` com `mutex`: instala o toolchain uma vez, antes do cargo em paralelo) |

O contrato, as armadilhas do moon 2.5.5 e o fluxo do CI estão no README da branch `v3` do `<bu>/github-actions` e em `platform-docs/platform/developer-guide/cicd-v3.md`.

## O CI do app precisa rodar a guarda

**O moon 2.5.5 não confere o status HTTP do `extends`.** Um 401/403/5xx com corpo vazio vira config vazia: o preset some, as tasks viram `noop`, o SAST baseline desaparece e o run sai com sucesso. A resposta ainda fica no cache (`.moon/cache/temp/`).

Por isso o CI do app roda `scripts/check-extends.sh`, da **mesma tag**, antes de qualquer task:

```yaml
- name: Guarda do extends remoto (moon-platform)
  run: |
    ref="$(grep -hoE 'moon-platform/[^/]+/' .moon/workspace.yml | head -1 | cut -d/ -f2)"
    curl -fsSL "https://raw.githubusercontent.com/be-growth/moon-platform/${ref}/scripts/check-extends.sh" | bash
```

Ele falha quando alguma URL não responde 2xx ou vem vazia, quando os stubs apontam para tags diferentes, quando falta task do contrato ou do baseline, ou quando um projeto com tag de preset tem `test` resolvido em `noop`.

## Versões

| Tag | Quem cria | Move? |
|---|---|---|
| `vX.Y.Z` | release-please, no merge do Release PR | Nunca |
| `vX` (ex.: `v1`) | `release.yml`, logo após cada release estável `vX.Y.Z` | Sim: sempre a última `vX.Y.Z` |

- **Release:** cada merge na `main` abre ou atualiza o Release PR, com a versão tirada dos Conventional Commits (`fix:` → patch, `feat:` → minor, `feat!:`/`BREAKING CHANGE` → major). O merge do Release PR cria a tag, o GitHub Release e move a major. Não crie tag à mão nem edite `CHANGELOG.md`/`.release-please-manifest.json`.
- **App na major (`.../v1/...`), o recomendado:** recebe correções e features sem PR no repo dele. Mudança que quebra o contrato (task renomeada, preset que passa a falhar onde antes passava) sobe o major, e o app só a recebe ao trocar `v1` por `v2`.
- **App na versão exata (`.../v1.0.3/...`):** congela a config; atualizar é trocar a tag em todas as URLs do `.moon/` no mesmo PR. Use para isolar um app de uma mudança.
- **A guarda reprova versões misturadas:** todas as URLs do `.moon/` de um repo usam a mesma ref.
- **Cache de 24h na máquina do dev.** O moon guarda cada `extends` remoto em `.moon/cache/temp/` e só baixa de novo depois de 24h (medido no 2.5.5). Depois que a major move, a máquina do dev pode rodar a config anterior por até um dia; `rm -rf .moon/cache/temp` força o download. O CI começa sem esse cache. O `raw.githubusercontent.com` também segura a resposta por alguns minutos.
- **Piso por BU:** o `moon-setup` do `<bu>/github-actions` resolve a major para a `vX.Y.Z` que ela aponta e reprova abaixo do `moon-platform-min` do `platform-env`.

## Por que público

O `extends` do moon só aceita caminho local ou URL HTTPS, sem mecanismo de autenticação. Repo privado exigiria `https://user:token@...` no `.moon/` de cada app: o token iria para o histórico de todos os repos, e o moon imprime a URL inteira, com a senha, nas mensagens de erro. Público, ninguém precisa de credencial, e alterar o conteúdo continua exigindo PR aqui.
