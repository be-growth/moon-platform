#!/usr/bin/env bash
# Guarda do `extends` remoto. Rode na raiz do repo do app, ANTES de qualquer task moon no CI.
#
# Por que existe: o moon 2.5.5 nao confere o status HTTP do `extends`. Um 401/403/5xx com corpo
# vazio (ou qualquer corpo que pareca YAML) vira config vazia, vai para o cache e o run segue
# com exit 0 -- as tasks herdadas somem caladas (o preset vira noop, o SAST baseline desaparece).
#
# Checa duas coisas:
#   1. Transporte: toda URL de `extends` em .moon/ responde 2xx, com corpo nao vazio, e todas
#      apontam para a mesma versao (tag) da plataforma.
#   2. Resultado: depois que o moon resolve a config, as tasks que a plataforma garante existem:
#      o contrato em todo projeto, o baseline no projeto raiz, e preset ligado por tag nao e noop.
set -euo pipefail

fail() { echo "::error title=moon-platform::$*" >&2; exit 1; }

[ -d .moon ] || fail "rode na raiz do repo (sem .moon/ aqui)"

# --- 1. Transporte ---------------------------------------------------------------------------
mapfile -t urls < <(grep -rhoE "^extends:[[:space:]]*['\"]?https://[^'\" ]+" .moon \
  --include='*.yml' --include='*.yaml' --exclude-dir=cache | sed -E "s/^extends:[[:space:]]*['\"]?//" | sort -u)
[ "${#urls[@]}" -gt 0 ] || fail "nenhum extends remoto em .moon/"

refs=""
for url in "${urls[@]}"; do
  body="$(curl -fsSL --retry 3 --retry-all-errors --max-time 20 "$url")" \
    || fail "extends inacessivel (status HTTP != 2xx): $url"
  [ -n "${body//[[:space:]]/}" ] || fail "extends veio vazio: $url"
  case "$url" in
    https://raw.githubusercontent.com/be-growth/moon-platform/*)
      refs+="$(cut -d/ -f6 <<<"$url")"$'\n' ;;
  esac
  echo "ok  $url"
done
n_refs="$(sort -u <<<"$refs" | sed '/^$/d' | wc -l)"
[ "$n_refs" -le 1 ] || fail "extends em versoes diferentes da plataforma: $(sort -u <<<"$refs" | xargs)"

# --- 2. Resultado ----------------------------------------------------------------------------
tasks="$(moon query tasks)"
projects="$(moon query projects)"

# Contrato (all.yml): toda task existe em todo projeto, mesmo que em noop.
missing="$(jq -r '
  .tasks | to_entries[] | .key as $p | .value as $t
  | ["format-check","lint","typecheck","test","build"][]
  | select($t[.] == null) | "\($p):\(.)"' <<<"$tasks")"
[ -z "$missing" ] || fail "tasks do contrato ausentes (all.yml nao carregou?): $(xargs <<<"$missing")"

# Baseline (baseline.yml): so no projeto raiz, e nunca noop.
root="$(jq -r '.projects[] | select(.source == ".") | .id' <<<"$projects")"
[ -n "$root" ] || fail "nenhum projeto moon na raiz do repo (o SAST baseline vive nele)"
for t in secrets-scan deps-scan; do
  jq -e --arg p "$root" --arg t "$t" '.tasks[$p][$t].script // empty | length > 0' <<<"$tasks" >/dev/null \
    || fail "baseline ausente: $root:$t (baseline.yml nao carregou?)"
done

# Presets por tag: projeto com a tag tem `test` de verdade, a menos que o moon.yml dele desligue.
for tag in go python-uv node-pnpm rust-cargo; do
  while read -r p; do
    [ -n "$p" ] || continue
    own="$(jq -r --arg p "$p" '.projects[] | select(.id == $p) | .config.tasks.test.command // empty' <<<"$projects")"
    [ "$own" = "noop" ] && continue
    cmd="$(jq -r --arg p "$p" '.tasks[$p].test.command // "noop"' <<<"$tasks")"
    [ "$cmd" != "noop" ] || fail "$p tem a tag '$tag' mas o test resolveu noop ($tag.yml nao carregou?)"
  done < <(jq -r --arg t "$tag" '.projects[] | select((.config.tags // []) | index($t)) | .id' <<<"$projects")
done

echo "moon-platform: extends ok (${#urls[@]} arquivos, versao $(sort -u <<<"$refs" | sed '/^$/d' | xargs))"
