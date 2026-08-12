#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
gitops_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd)
prepare="$gitops_dir/scripts/prepare-upgrade.sh"
read_image_os="$gitops_dir/scripts/read-image-os.sh"

for command_name in rg yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done

os_output=$("$read_image_os" \
  --os-release-file "$test_dir/fixtures/os-release" --format args)
[[ "$os_output" == '--image-os-id testlinux --image-os-version 9.9' ]] || {
  printf 'unexpected image OS evidence output: %s\n' "$os_output" >&2
  exit 1
}

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

zookeeper_output=$("$prepare" --component zookeeper --version 9.9.9-test \
  --image-digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
  --image-os-id testlinux --image-os-version 9.9)
assert_changed_files 3 "$zookeeper_output"
printf '%s\n' "$zookeeper_output" | rg -q '^\+        app\.kubernetes\.io/version: 9\.9\.9-test$'
printf '%s\n' "$zookeeper_output" | rg -q '^\+      id: testlinux$'
printf '%s\n' "$zookeeper_output" | rg -q '^\+      versionId: 9\.9$'
if printf '%s\n' "$zookeeper_output" | rg -q '^[+-] {10}app\.kubernetes\.io/version:'; then
  printf '%s\n' 'ZooKeeper preview changed the immutable PVC template version label' >&2
  exit 1
fi

if "$prepare" --component zookeeper --version 9.9.9-test \
  --image-digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
  >/dev/null 2>&1; then
  printf '%s\n' 'ZooKeeper preview accepted missing container OS evidence' >&2
  exit 1
fi

printf '%s\n' 'Platform Release upgrade workflow tests passed'
