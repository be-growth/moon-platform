# moon-platform

Config compartilhada do [moon](https://moonrepo.dev) da plataforma BeGrowth (CI/CD v3): o contrato de tasks, os presets por linguagem, o SAST baseline e o fragmento de workspace. Os repos de app **não copiam** estes arquivos: estendem por URL, pinando uma tag.

> O repo é público de propósito. O conteúdo é só definição de task, sem segredo, e o `extends` do moon não tem como autenticar sem pôr credencial em arquivo versionado (ver "Por que público").

## Como um repo usa

`.moon/workspace.yml`:

```yaml
extends: 'https://raw.githubusercontent.com/be-growth/moon-platform/v1.0.0/workspace.yml'

projects:
  globs: ['services/*', 'libs/*', '!**/*.md']
  sources:
    repo: '.'   # todo repo precisa de um projeto na raiz: o baseline vive nele
```

Um stub em `.moon/tasks/` por arquivo da plataforma que o repo usa. Cada um tem só o `extends`; quem decide quais projetos herdam é o `inheritedBy` do arquivo remoto:

```yaml
# .moon/tasks/platform-all.yml
extends: 'https://raw.githubusercontent.com/be-growth/moon-platform/v1.0.0/tasks/all.yml'
```

`all.yml` e `baseline.yml` são obrigatórios. Os outros entram conforme o repo: `deployable.yml` se tem imagem, e o preset da linguagem.

| Arquivo | Herdado por | Conteúdo |
|---|---|---|
| `workspace.yml` | o `.moon/workspace.yml` do app | `vcs` (git, GitHub, `main`), hooks locais (`pre-commit`: `format-check` + `lint` do staged; `commit-msg`: Conventional Commits) e `pipeline.installDependencies: false` |
| `tasks/all.yml` | todo projeto | Tasks do contrato em `noop` + `implicitInputs` + a interna `sources` |
| `tasks/baseline.yml` | só o projeto na raiz | `secrets-scan` (gitleaks) e `deps-scan` (`trivy fs`). Não sobrescreva |
| `tasks/deployable.yml` | tag `deployable` | Marcador `package`: quem vira imagem |
| `tasks/go.yml` | tag `go` | gofmt, `go vet`, `go build`, `go test` |
| `tasks/python-uv.yml` | tag `python-uv` | ruff, mypy, pytest, `uv build` |
| `tasks/node-pnpm.yml` | tag `node-pnpm` | `pnpm install` + scripts do `package.json` |
| `tasks/rust-cargo.yml` | tag `rust-cargo` | `cargo fmt --check`, clippy `-D warnings`, `cargo check`, `cargo test`, `cargo build` |

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

- **Tag por release** (`vX.Y.Z`). Os apps pinam a tag; a branch `main` nunca entra numa URL de `extends`.
- **Tag não se move.** Correção = tag nova. O `raw.githubusercontent.com` faz cache por alguns minutos e o moon guarda a resposta em `.moon/cache/temp/`, então mover uma tag dá resultados diferentes conforme a máquina.
- **Atualizar um app** = trocar a tag em todas as URLs do `.moon/` no mesmo PR (a guarda reprova versões misturadas).
- Mudança que quebra o contrato (task renomeada, preset que passa a falhar onde antes passava) sobe o major.

## Por que público

O `extends` do moon só aceita caminho local ou URL HTTPS, sem mecanismo de autenticação. Repo privado exigiria `https://user:token@...` no `.moon/` de cada app: o token iria para o histórico de todos os repos, e o moon imprime a URL inteira, com a senha, nas mensagens de erro. Público e com tag imutável, ninguém precisa de credencial, e alterar o conteúdo continua exigindo PR aqui.
