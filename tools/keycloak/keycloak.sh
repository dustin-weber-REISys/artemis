#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() { printf '%s\n' "$*" >&2; exit 2; }
need() { [[ -n ${!1:-} ]] || fail "Set $1."; }

case "${1:-help}" in
  help|--help|-h)
    cat <<'EOF'
Keycloak configuration toolkit
  export REALM     Online partial export to /exports/realm-export.json.
                  Requires KEYCLOAK_URL and KEYCLOAK_USER; prompts for password.
  export-offline [REALM]
                  Native database export to /exports, skipping users.
                  Requires KC_DB* settings and an offline database.
  apply           Apply reviewed /config/*.json and /config/*.yaml files.
                  Requires KEYCLOAK_URL and credentials via /run/secrets.
EOF
    ;;
  export)
    [[ $# == 2 ]] || fail 'Usage: export REALM'
    need KEYCLOAK_URL
    need KEYCLOAK_USER
    [[ -d /exports && -w /exports ]] || fail 'Mount a writable directory at /exports.'
    [[ ! -e /exports/realm-export.json ]] || fail 'Use a fresh export directory.'
    session=$(mktemp -d)
    output=$(mktemp /exports/.partial.XXXXXX)
    trap 'rm -rf "$session"; rm -f "$output"' EXIT
    /opt/keycloak/bin/kcadm.sh config credentials \
      --config "$session/kcadm.config" \
      --server "$KEYCLOAK_URL" --realm "${KEYCLOAK_LOGINREALM:-master}" \
      --user "$KEYCLOAK_USER"
    /opt/keycloak/bin/kcadm.sh create partial-export \
      --config "$session/kcadm.config" -r "$2" \
      -q exportClients=true -q exportGroupsAndRoles=true -o > "$output"
    [[ -s "$output" ]] || fail 'Keycloak returned an empty export.'
    mv "$output" /exports/realm-export.json
    printf '%s\n' 'Saved /exports/realm-export.json; review before using or committing.'
    ;;
  export-offline)
    [[ $# -le 2 ]] || fail 'Usage: export-offline [REALM]'
    [[ -d /exports && -w /exports ]] || fail 'Mount a writable directory at /exports.'
    shopt -s nullglob dotglob
    existing=(/exports/*)
    [[ ${#existing[@]} == 0 ]] || fail 'Use an empty export directory.'
    args=(export --dir /exports --users skip)
    [[ $# == 1 ]] || args+=(--realm "$2")
    exec /opt/keycloak/bin/kc.sh "${args[@]}"
    ;;
  apply)
    [[ $# == 1 ]] || fail 'Usage: apply'
    need KEYCLOAK_URL
    shopt -s nullglob
    files=(/config/*.json /config/*.yaml)
    [[ ${#files[@]} -gt 0 ]] || fail 'Mount reviewed JSON/YAML files at /config.'
    # Spring configtree reads keycloak.password or keycloak.client-secret from files.
    export SPRING_CONFIG_IMPORT=configtree:/run/secrets/
    export IMPORT_FILES_LOCATIONS='file:/config/*.json,file:/config/*.yaml'
    export IMPORT_VARSUBSTITUTION_ENABLED=true
    # Reconcile even when the input checksum is unchanged.
    export IMPORT_CACHE_ENABLED=false
    args=(--keycloak.ssl-verify=true --import.validate=true)
    # Adoption defaults: do not prune missing resources. This is not a dry run;
    # supplied fields and mappings can still change existing authentication.
    for resource in authentication-flow group required-action client-scope \
      scope-mapping client-scope-mapping component sub-component \
      identity-provider identity-provider-mapper role client \
      client-authorization-resources client-authorization-policies \
      client-authorization-scopes message-bundles workflow; do
      args+=("--import.managed.$resource=no-delete")
    done
    exec java -jar /app/keycloak-config-cli.jar "${args[@]}"
    ;;
  *) fail "Unknown command: $1 (use help)." ;;
esac
