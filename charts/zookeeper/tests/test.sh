#!/usr/bin/env bash
set -euo pipefail

chart_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
rendered=$(mktemp "${TMPDIR:-/tmp}/zookeeper-test.XXXXXX.yaml")
sandbox=$(mktemp "${TMPDIR:-/tmp}/zookeeper-sandbox.XXXXXX.yaml")
trap 'rm -f "$rendered" "$sandbox"' EXIT

helm lint "$chart_dir" >/dev/null
if helm template invalid "$chart_dir" --set replicaCount=2 >/dev/null 2>&1; then
  printf '%s\n' 'expected a two-member quorum to fail' >&2
  exit 1
fi

helm template zookeeper "$chart_dir" --namespace example-platform > "$rendered"
rg -q '^kind: StatefulSet$' "$rendered"
rg -q 'replicas: 3' "$rendered"
rg -q 'server\.1=zookeeper-zookeeper-0\.zookeeper-zookeeper-headless' "$rendered"
rg -q 'server\.3=zookeeper-zookeeper-2\.zookeeper-zookeeper-headless' "$rendered"
rg -q '/data/data/myid' "$rendered"
rg -q 'key: ActiveMQArtemis' "$rendered"
rg -q 'operator: Exists' "$rendered"
rg -q 'maxUnavailable: 1' "$rendered"
rg -q 'topologyKey: "topology.kubernetes.io/zone"' "$rendered"
kubeconform -strict -ignore-missing-schemas -summary "$rendered" >/dev/null

helm template sandbox "$chart_dir" \
  --set enabled=false \
  --set haMode=none \
  --set replicaCount=1 > "$sandbox"
if rg -q '[^[:space:]]' "$sandbox"; then
  printf '%s\n' 'disabled sandbox composition rendered resources' >&2
  exit 1
fi

printf '%s\n' 'zookeeper focused chart tests passed'
