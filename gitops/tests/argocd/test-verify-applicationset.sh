#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
verifier="$repo_root/scripts/verify-argocd-applicationset.sh"

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-applicationset-test.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$temp_dir/bin"

cat > "$temp_dir/bin/kubectl" <<'EOF'
#!/bin/sh
case " $* " in
  *' get deployment '*)
    printf '%s\n' '{"spec":{"replicas":1},"status":{"availableReplicas":1}}'
    ;;
  *' get applicationset '*)
    printf '%s\n' '{"status":{"conditions":[{"type":"ResourcesUpToDate","status":"True","message":"ok"}]}}'
    ;;
  *' get appproject '*)
    printf '{"spec":{"destinations":[{"server":"https://kubernetes.default.svc","namespace":"%s"}]}}\n' \
      "${MOCK_PROJECT_NAMESPACE:-artemis-int-sky}"
    ;;
  *' get application '*)
    if [ "${MOCK_INVALID_SPEC:-false}" = true ]; then
      conditions='[{"type":"InvalidSpecError","message":"destination is not permitted"}]'
    else
      conditions='[]'
    fi
    printf '{"metadata":{"ownerReferences":[{"kind":"ApplicationSet","name":"test-artemis-workloads"}]},"spec":{"destination":{"server":"https://kubernetes.default.svc","namespace":"artemis-int-sky"}},"status":{"conditions":%s}}\n' \
      "$conditions"
    ;;
  *)
    printf 'unexpected kubectl arguments: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$temp_dir/bin/kubectl"

PATH="$temp_dir/bin:$PATH" \
  "$verifier" \
    --context test-context \
    --argocd-namespace argocd \
    --environment test >"$temp_dir/pass.out"
grep -Fq 'Approved project destination: https://kubernetes.default.svc/artemis-int-sky' "$temp_dir/pass.out"
grep -Fq 'ApplicationSet verification: PASS (1 enabled broker pairs)' "$temp_dir/pass.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_PROJECT_NAMESPACE=wrong-namespace \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/project-mismatch.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted a disallowed project destination' >&2
  exit 1
fi
grep -Fq 'does not allow destination https://kubernetes.default.svc namespace artemis-int-sky' \
  "$temp_dir/project-mismatch.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_INVALID_SPEC=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/invalid-spec.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted an Application InvalidSpecError' >&2
  exit 1
fi
grep -Fq 'has InvalidSpecError: destination is not permitted' "$temp_dir/invalid-spec.out"

printf '%s\n' 'ApplicationSet verification tests passed'
