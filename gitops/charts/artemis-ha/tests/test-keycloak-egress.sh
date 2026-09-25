#!/usr/bin/env bash
set -euo pipefail

chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gitops_dir=$(CDPATH= cd -- "$chart_dir/../.." && pwd)
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-keycloak-tests.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
helm_args=(--set ha.coordinationId=keycloak-test --set zookeeper.connectString=zookeeper:2181)

helm template artemis "$chart_dir" "${helm_args[@]}" > "$temp_dir/local.yaml"

# Example-only documentation range: rendered offline, never applied.
cat > "$temp_dir/egress.yaml" <<'YAML'
networkPolicy:
  extraEgress:
    - to:
        - ipBlock:
            cidr: 192.0.2.0/24
      ports:
        - protocol: TCP
          port: 443
YAML
for environment in test nonprod; do
  helm template artemis "$chart_dir" "${helm_args[@]}" \
    -f "$gitops_dir/environments/$environment/artemis-values.yaml" \
    -f "$temp_dir/egress.yaml" > "$temp_dir/$environment.yaml"
done

helm template artemis "$chart_dir" "${helm_args[@]}" \
  --set keycloak.enabled=false > "$temp_dir/disabled.yaml"
python3 - "$temp_dir" <<'PYTEST'
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
for mode in ("local", "test", "nonprod", "disabled"):
    docs = json.loads(subprocess.check_output(
        ["yq", "eval-all", "-o=json", "[.]", str(root / f"{mode}.yaml")], text=True))
    policy = next(d for d in docs if d and d.get("kind") == "NetworkPolicy"
                  and d["metadata"]["name"] == "artemis-artemis-ha-allow")
    rules = policy["spec"]["egress"]
    peers = [peer for rule in rules for peer in rule.get("to", [])
             if peer.get("podSelector", {}).get("matchLabels", {}).get(
                 "app.kubernetes.io/name") == "keycloak"]
    assert len(peers) == (1 if mode == "local" else 0), mode
    oidc = [d for d in docs if d and d.get("kind") == "ConfigMap"
            and "hawtio-oidc.properties" in d.get("data", {})]
    assert len(oidc) == (0 if mode == "disabled" else 1), mode
    if oidc:
        assert "code_challenge_method = S256" in oidc[0]["data"]["hawtio-oidc.properties"]
    broker = next(d for d in docs if d and d.get("kind") == "ActiveMQArtemis")
    java_args = next(e["value"] for e in broker["spec"]["env"]
                     if e["name"] == "JAVA_ARGS_APPEND")
    assert ("-Dhawtio.oidcConfig=" in java_args) == (mode != "disabled"), mode
    if mode in ("test", "nonprod"):
        external = [r for r in rules if r.get("to") == [{"ipBlock": {"cidr": "192.0.2.0/24"}}]]
        assert len(external) == 1, mode
        assert external[0]["ports"] == [{"protocol": "TCP", "port": 443}], mode
print("Keycloak local/external egress tests passed")
PYTEST
