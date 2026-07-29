#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
client_dir="$script_dir/client"
image=${IMAGE:-artemis-validation-client:local}
maven=${MAVEN:-mvn}

if docker build \
    -f "$client_dir/Dockerfile.local" \
    -t "$image" \
    "$client_dir"; then
  exit 0
fi

printf '%s\n' \
  'containerized Maven build failed; trying the host-package fallback' >&2
command -v "$maven" >/dev/null 2>&1 || {
  printf 'host Maven command not found: %s\n' "$maven" >&2
  exit 2
}

"$maven" -B -ntp -f "$client_dir/pom.xml" package
docker build \
  -f "$client_dir/Dockerfile.prebuilt" \
  -t "$image" \
  "$client_dir"
