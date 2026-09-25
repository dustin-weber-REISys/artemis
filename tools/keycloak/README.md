# Keycloak configuration toolkit

One image containing native `kcadm.sh` / `kc.sh` and the third-party
`keycloak-config-cli`. Build and use this on the work laptop. This repository's
offline checkout must not connect to the real deployment.

## Build

Use Docker Desktop or Docker Engine (Bash examples also work in WSL). Select
the exact deployed Keycloak image and a compatible, versioned config-cli image
from its [release documentation](https://github.com/adorsys/keycloak-config-cli#docker).
Replace the placeholders; they are deliberately not runnable image tags.
For repeatable builds, use image digests. The config-cli image's Java runtime
must support both tools; modern Keycloak 26 builds use Java 21.

```bash
cd tools/keycloak
docker build \
  --build-arg KEYCLOAK_IMAGE=quay.io/keycloak/keycloak:YOUR_KEYCLOAK_VERSION \
  --build-arg CONFIG_CLI_IMAGE=adorsys/keycloak-config-cli:YOUR_COMPATIBLE_TAG \
  -t keycloak-toolkit:local .
docker run --rm keycloak-toolkit:local help
```

Approved registry mirrors can replace either image reference. The build context
allows only the Dockerfile and script, so local credentials and exports are not
sent to the builder. Custom provider JARs needed for offline exports must be in
the selected Keycloak image.

## Export from the running server

This prompts for your password inside the container; it is not a build argument
or shell-history value. Tokens are temporary and removed on exit.

```bash
mkdir -p exports/preprod
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e KEYCLOAK_URL=https://keycloak-preprod.example.invalid \
  -e KEYCLOAK_USER=YOUR_ADMIN_USER \
  -e KEYCLOAK_LOGINREALM=master \
  -v "$PWD/exports/preprod:/exports" \
  keycloak-toolkit:local export YOUR_REALM
```

Repeat with a fresh output directory for each realm. Include `/auth` in the URL
if the server uses that context path. The account needs the permissions required
by the selected server version for partial export, clients, groups, and roles.
Interactive password login requires an account allowed to use that grant; a
browser-only/MFA account may need a separately approved automation identity.

This calls the online partial-export API. It exports realm configuration and
selected resources, excludes users, and masks secrets. It is not a complete
backup or a guaranteed complete representation of custom extensions. Large
realms can make this operation expensive. See
[Keycloak export behavior](https://www.keycloak.org/server/importExport).

## Export all realms from an offline database

Use an isolated restored database, or stop every Keycloak node before exporting
the original database. Do not run this against an active production database.
Use the matching Keycloak image/provider build. This is a native server launch
that reads the database, not a request to the Admin API.

Create a local `.env.offline` with `KC_DB`, `KC_DB_URL`, `KC_DB_USERNAME`, and
`KC_DB_PASSWORD` using the approved database connection values. Protect that
file with `chmod 600 .env.offline`; it is ignored by Git and the Docker build.

```bash
mkdir -p exports/offline
docker run --rm \
  --env-file .env.offline \
  -v "$PWD/exports/offline:/exports" \
  keycloak-toolkit:local export-offline
```

The directory must be writable by container UID 65534 (on Linux, set its owner
accordingly). Omit `--user` here: native export may rebuild files under
`/opt/keycloak`, which belongs to UID 65534. Append a realm name to limit the
export. Users are always excluded, but exports can still contain secrets.
Sessions/events are not included; retain database backups separately.

## Prepare and apply desired configuration

Keep raw exports in ignored `exports/`. Create a separate reviewed directory,
for example `desired/preprod/`, with the JSON/YAML you intend to manage. Preserve
the correct `realm` value. Remove user data, unnecessary generated IDs only
where safe, and secret values or masked `**********` values. Restore secret
fields using references where necessary. Never blindly apply a partial export.
The configuration files themselves select the target realms.

Store automation credentials in ignored `secrets/`, with each value in a file:

- Password authentication: `keycloak.password`; supply `KEYCLOAK_USER` below.
- Service account: `keycloak.client-secret`; set `KEYCLOAK_GRANTTYPE=client_credentials`
  and `KEYCLOAK_CLIENTID` instead of `KEYCLOAK_USER`.

Use the minimum realm-management permissions for the managed resources. Create
secret files through your approved secret tooling, with a private directory and
mode 600 files. In CI, mount them from Vault/your secret integration. A reference
inside desired JSON can use `$(file:UTF-8:/run/secrets/smtp.password)`; provide
that additional file at runtime. Substitution is textual, so values embedded in
JSON strings must be JSON-escaped when they contain quotes or backslashes.

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e KEYCLOAK_URL=https://keycloak-preprod.example.invalid \
  -e KEYCLOAK_USER=YOUR_AUTOMATION_USER \
  -e KEYCLOAK_LOGINREALM=master \
  -v "$PWD/desired/preprod:/config:ro" \
  -v "$PWD/secrets:/run/secrets:ro" \
  keycloak-toolkit:local apply
```

**Apply changes the server immediately.** It is not a plan/diff command and is
not transactional; a failed run may have applied some changes. Validate against
a disposable matching server first, then preprod. The wrapper disables pruning
of missing resources, but supplied settings and mappings can still change
access. Deletion requires a separately reviewed change to the wrapper's
management policy. See [resource management](https://github.com/adorsys/keycloak-config-cli/blob/main/docs/MANAGED.md).

Keep the complete shared Hawtio redirect-URI list in one owned configuration.
Test browser login, viewer/admin claims, and direct Jolokia authorization after
applying. Reverting Git can restore settings on the next apply, but does not
undo every side effect or restore deleted data.

TLS verification stays enabled. For an internal CA, mount a Java truststore and
provide `JAVA_TOOL_OPTIONS` with the JVM truststore settings; config-cli also
supports its own `KEYCLOAK_TLS_TRUSTSTOREPATH` settings. Do not disable TLS
verification. Avoid debug/trace logging of realm data and credentials.

## GitOps integration

### Prepare an additive Hawtio redirect update

Use `plan-redirects.py` on the work laptop with Python 3. It consumes a fresh
toolkit realm export and the existing Artemis inventory generator's JSON. It
does not connect to Keycloak. From the repository root, after replacing the
inventory's placeholder hosts, issuer URLs, and client IDs:

```bash
python3 gitops/scripts/hawtio-redirects.py --require-real-hosts \
  > tools/keycloak/exports/hawtio-inventory.json
python3 tools/keycloak/plan-redirects.py \
  --export tools/keycloak/exports/preprod/realm-export.json \
  --inventory tools/keycloak/exports/hawtio-inventory.json \
  --issuer https://keycloak-preprod.example.com/realms/YOUR_REALM \
  --client-id YOUR_HAWTIO_CLIENT
```

Without `--output-dir`, this is a dry run that prints the before/after list,
additions, and warnings. Add `--output-dir tools/keycloak/exports/redirect-plan`
to create a **new** directory containing `review.json` and, if anything changes,
`desired/hawtio-redirects.json`. Existing output directories are refused. A no-op
produces only the review report. The inventory includes disabled cells so login
can be configured before activation, and combines environments sharing a client.

The candidate contains only `realm`, one `clientId`, and the merged
`redirectUris`. Legacy URLs, duplicates, and the standalone `*` remain intact;
new URLs are deduplicated. No secrets, realm settings, roles, origins, or other
client fields are copied from the export. Wildcard removal is a separate reviewed
change: adding explicit entries while keeping `*` does not tighten the allowlist.
The planner rejects placeholder targets and config-cli substitution expressions.

Review the report, then use the **existing `apply` command above**, mounting only
`tools/keycloak/exports/redirect-plan/desired` at `/config`. Do not mount the
plan's parent directory (the review report is not an import file). Configure
`KEYCLOAK_URL` to the server portion of the reviewed issuer, including `/auth`
when applicable; the candidate selects the realm. Raw exports contain no reliable
server provenance: matching realm names alone cannot prove an export came from
the right server, so verify its source yourself.

The merged list is additive relative to the export, not a live atomic append.
Re-export and regenerate immediately before an approved apply, and serialize
updates with other administrators/pipelines; a stale snapshot can overwrite URLs
added since export. Do not schedule repeated applies of an old generated file.
First validate the pinned config-cli version against a disposable matching server:
check that only redirect URIs change and that login still works. This offline
planner cannot prove server-side preservation or version compatibility.

A future pipeline should trigger on merged topology/environment identity changes,
generate the inventory, obtain a fresh export, prepare/review the plan, then invoke
the same toolkit apply step on a runner with approved connectivity. Use one owner
per shared client, including all environments that use it. No live workflow is
installed here because the runner, credentials, and deployed versions are not yet
established. Retired URLs require separate reviewed cleanup.

Offline validation (no Docker, credentials, or network required for planner tests):

```bash
python3 tools/keycloak/test-plan-redirects.py
python3 gitops/tests/topology/test-hawtio-redirects.py
```

The inventory tests additionally require the repository's yq v4.

### Apply reviewed configuration through GitOps

Commit only reviewed desired files and the image source/pins. Argo CD can run
the built image as a Job with `args: ["apply"]`, mounting configuration at
`/config` and secrets at `/run/secrets`. This toolkit does not install that Job
or change the existing Artemis Applications. Schedule reconciliation separately
if console drift must be corrected between Git changes. Import caching is
disabled so each invocation checks desired state again.

The deployment manifests, custom providers/themes, and secrets remain separate
from realm JSON. Version compatibility and end-to-end behavior must be checked
on the work laptop; the offline repository does not have the real server.
