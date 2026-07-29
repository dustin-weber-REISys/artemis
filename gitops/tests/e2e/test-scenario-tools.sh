#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
runner="$repo_root/scripts/eks-scenario.sh"
validator="$repo_root/scripts/validate-scenarios.sh"
temp_root=$(mktemp -d)
trap 'rm -rf -- "$temp_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_exit() {
  local expected=$1
  shift
  local actual
  if "$@" >"$temp_root/command.stdout" 2>"$temp_root/command.stderr"; then
    actual=0
  else
    actual=$?
  fi
  [[ "$actual" -eq "$expected" ]] || {
    sed -n '1,120p' "$temp_root/command.stdout" >&2
    sed -n '1,120p' "$temp_root/command.stderr" >&2
    fail "expected exit $expected, got $actual: $*"
  }
}

"$validator" --report "$temp_root/validation.json" >/dev/null
yq -e '.status == "PASS" and .errors == 0' "$temp_root/validation.json" >/dev/null ||
  fail 'baseline acceptance artifact validation did not pass'

cp "$test_dir/acceptance-plan.yaml" "$temp_root/missing-case.yaml"
yq -i 'del(.cases[] | select(.id == "safe-manual-failback"))' "$temp_root/missing-case.yaml"
expect_exit 1 "$validator" --file "$temp_root/missing-case.yaml" --report "$temp_root/missing-case-report.json"
grep -Fq 'missing required acceptance coverage: safe-manual-failback' "$temp_root/command.stderr" ||
  fail 'validator did not protect required acceptance coverage'
yq -e '.status == "FAIL" and .errors > 0' "$temp_root/missing-case-report.json" >/dev/null ||
  fail 'failed validation report is not valid structured JSON'

action_ids=$("$runner" --list-actions | awk -F '\t' '{print $1}')
grep -Fxq delete-single-pod <<< "$action_ids" || fail 'runner action list omits delete-single-pod'
grep -Fxq inspect-zone-nodes <<< "$action_ids" || fail 'runner action list omits inspect-zone-nodes'

manual_report="$temp_root/manual.json"
expect_exit 3 "$runner" \
  --scenario clean-install \
  --context test-context \
  --cluster test-cluster \
  --namespace test-namespace \
  --execute \
  --report "$manual_report"
yq -e '.status == "MANUAL_REQUIRED" and .acceptanceResult == "NOT_EVALUATED"' "$manual_report" >/dev/null ||
  fail 'manual execution was not explicitly rejected in its report'

quoted_target=$'pod-"quoted"\\path\nsecond-line'
quoted_report="$temp_root/quoted.json"
"$runner" \
  --scenario active-broker-pod-delete \
  --context test-context \
  --cluster test-cluster \
  --namespace test-namespace \
  --target-pod "$quoted_target" \
  --report "$quoted_report" >/dev/null
QUOTED_TARGET=$quoted_target yq -e '.target == strenv(QUOTED_TARGET)' "$quoted_report" >/dev/null ||
  fail 'runner report did not preserve JSON-sensitive target text'
yq -e '.status == "ACTION_PLANNED" and .acceptanceResult == "NOT_EVALUATED"' "$quoted_report" >/dev/null ||
  fail 'dry-run report has incorrect execution semantics'

fake_bin="$temp_root/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == config && "${2-}" == current-context ]]; then
  printf '%s\n' 'test-context'
elif [[ "${1-}" == config && "${2-}" == view ]]; then
  printf '%s\n' 'test-cluster'
else
  printf '%s\n' "$*" >> "$KUBECTL_LOG"
fi
EOF
chmod 755 "$fake_bin/kubectl"

kubectl_log="$temp_root/kubectl.log"
expect_exit 2 env PATH="$fake_bin:$PATH" KUBECTL_LOG="$kubectl_log" "$runner" \
  --scenario active-broker-pod-delete \
  --context test-context \
  --cluster test-cluster \
  --namespace test-namespace \
  --target-pod broker-0 \
  --execute \
  --report "$temp_root/unconfirmed.json"
[[ ! -e "$kubectl_log" ]] || fail 'kubectl ran before exact destructive confirmations were validated'

executed_report="$temp_root/executed.json"
env PATH="$fake_bin:$PATH" KUBECTL_LOG="$kubectl_log" "$runner" \
  --scenario active-broker-pod-delete \
  --context test-context \
  --cluster test-cluster \
  --namespace test-namespace \
  --confirm-context test-context \
  --confirm-cluster test-cluster \
  --confirm-namespace test-namespace \
  --target-pod broker-0 \
  --execute \
  --report "$executed_report" >/dev/null
grep -Fq -- '--context test-context --namespace test-namespace delete pod broker-0 --wait=false' "$kubectl_log" ||
  fail 'confirmed destructive action did not invoke the expected kubectl command'
yq -e '
  .status == "ACTION_EXECUTED" and
  .acceptanceResult == "NOT_EVALUATED" and
  .destructiveSafeguard == "exact-context-cluster-namespace-confirmations-validated"
' "$executed_report" >/dev/null ||
  fail 'executed action report lost safeguard or acceptance semantics'

printf '%s\n' 'scenario tooling tests: PASS'
