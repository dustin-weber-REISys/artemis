#!/usr/bin/env python3
"""Print exact Hawtio callbacks from topology; never contact Keycloak."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def read_yaml(path):
    return json.loads(subprocess.check_output(
        ["yq", "-o=json", ".", str(path)], text=True
    ))


def inventory(root, environments, require_real_hosts=False):
    clients = {}
    seen_hosts = set()
    for environment in environments:
        topology = read_yaml(root / "argocd/topology" / f"{environment}.yaml")
        identity = read_yaml(root / "environments" / environment / "artemis-values.yaml")["keycloak"]
        key = (identity["issuerUrl"], identity["clientId"])
        client = clients.setdefault(key, {
            "issuerUrl": key[0], "clientId": key[1], "cells": [], "redirectUris": []
        })
        for cell in topology["workloadCells"]:
            host = cell["managementHost"]
            labels = host.split(".") if isinstance(host, str) else []
            if (not labels or len(host) > 253 or len(labels) < 2 or
                    any(not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", label)
                        for label in labels)):
                raise ValueError(f"{environment}/{cell['workloadCellName']}: invalid managementHost")
            if require_real_hosts and (host.lower().endswith(".invalid") or "placeholder" in host.lower()):
                raise ValueError(f"{environment}/{cell['workloadCellName']}: replace placeholder managementHost")
            if host.lower() in seen_hosts:
                raise ValueError(f"duplicate managementHost: {host}")
            seen_hosts.add(host.lower())
            uri = f"https://{host}/console"
            client["cells"].append({
                "environment": environment, "workloadCellName": cell["workloadCellName"],
                "enabled": str(cell["enabled"]).lower() == "true", "redirectUri": uri,
            })
            client["redirectUris"].append(uri)
    return {"clients": list(clients.values())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", action="append", choices=["test", "nonprod", "prod"],
                        help="Repeat to combine environments sharing a Keycloak client; default: all")
    parser.add_argument("--format", choices=["json", "urls"], default="json")
    parser.add_argument("--require-real-hosts", action="store_true",
                        help="Reject placeholder hostnames before preparing a live allowlist")
    args = parser.parse_args()
    try:
        report = inventory(ROOT, list(dict.fromkeys(args.environment or ["test", "nonprod", "prod"])),
                           args.require_real_hosts)
        if args.format == "urls":
            if len(report["clients"]) != 1:
                raise ValueError("URL-only output requires environments sharing exactly one client")
            print("\n".join(report["clients"][0]["redirectUris"]))
        else:
            print(json.dumps(report, indent=2))
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"hawtio-redirects: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
