#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
gitops_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd)
prepare="$gitops_dir/scripts/prepare-upgrade.sh"

for command_name in rg yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done

assert_changed_files() {
  expected=$1
  output=$2
  actual=$(printf '%s\n' "$output" | rg -c '^--- a/gitops/')
  [[ "$actual" == "$expected" ]] || {
    printf 'expected %s changed files, got %s\n%s\n' "$expected" "$actual" "$output" >&2
    exit 1
  }
}

kubernetes_output=$("$prepare" --component kubernetes --version 9.9.9-test)
assert_changed_files 1 "$kubernetes_output"
printf '%s\n' "$kubernetes_output" | rg -q '^\+  kubernetesVersion: 9\.9\.9-test$'

if "$prepare" --component node-os --version 9.9.9-test >/dev/null 2>&1; then
  printf '%s\n' 'upgrade workflow still accepts EKS node OS as a component' >&2
  exit 1
fi

zookeeper_output=$("$prepare" --component zookeeper --version 9.9.9-test)
assert_changed_files 3 "$zookeeper_output"
printf '%s\n' "$zookeeper_output" | rg -q '^\+        app\.kubernetes\.io/version: 9\.9\.9-test$'
printf '%s\n' "$zookeeper_output" | rg -q '^\+    tag: 9\.9\.9-test$'
printf '%s\n' "$zookeeper_output" | rg -q '^\+          image: example\.invalid/ecr-mirror/zookeeper:9\.9\.9-test$'
if printf '%s\n' "$zookeeper_output" | rg -q '^[+-] {10}app\.kubernetes\.io/version:'; then
  printf '%s\n' 'ZooKeeper preview changed the immutable PVC template version label' >&2
  exit 1
fi

os_rebuild_output=$("$prepare" --component zookeeper --version 3.9.5 \
  --image-tag 3.9.5-os2)
assert_changed_files 2 "$os_rebuild_output"
printf '%s\n' "$os_rebuild_output" | rg -q '^\+    tag: 3\.9\.5-os2$'
printf '%s\n' "$os_rebuild_output" | rg -q '^\+          image: example\.invalid/ecr-mirror/zookeeper:3\.9\.5-os2$'

if "$prepare" --component zookeeper --version 9.9.9-test \
  --image-tag 'invalid/tag' >/dev/null 2>&1; then
  printf '%s\n' 'ZooKeeper preview accepted an invalid container image tag' >&2
  exit 1
fi

printf '%s\n' 'Platform Release upgrade workflow tests passed'
