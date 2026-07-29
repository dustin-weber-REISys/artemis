#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
report="$repo_root/../reports/compose-validation.json"

while (($#)); do
  case "$1" in
    --report) report=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ "$report" != /* ]]; then
  report="$repo_root/$report"
fi
mkdir -p "$(dirname -- "$report")"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  printf '%s\n' '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"compose","status":"SKIP","reason":"docker compose unavailable"}' > "$report"
  printf '%s\n' 'compose validation: SKIP (docker compose unavailable)'
  exit 0
fi

compose_args=(--env-file "$repo_root/.env.example" -f "$repo_root/compose.yaml")
if rendered=$(docker compose "${compose_args[@]}" config) \
  && docker compose --profile smoke "${compose_args[@]}" config --quiet \
  && grep -Fq 'AMQ_EXTRA_ARGS: --relax-jolokia' <<<"$rendered"; then
  printf '%s\n' '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"compose","status":"PASS","file":"local/compose.yaml"}' > "$report"
  printf '%s\n' 'compose validation: PASS'
else
  printf '%s\n' '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"compose","status":"FAIL","file":"local/compose.yaml"}' > "$report"
  printf '%s\n' 'compose validation: FAIL' >&2
  exit 1
fi
