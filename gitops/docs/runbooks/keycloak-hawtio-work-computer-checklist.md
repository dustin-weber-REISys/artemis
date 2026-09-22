# Keycloak + Hawtio: work-computer checklist

Use this checklist to collect what we need to finish the integration. Run the
commands on your authorized work computer, against the intended test environment.
The commands inspect existing resources; they do not change the deployment.

**You do not need to solve each failure before moving on.** Record the result or
error and continue. Mark anything you cannot access as `unknown`.

Keep raw evidence on your work computer. Before sending anything back, remove
passwords, tokens, cookies, authorization headers, personal information, and
sensitive infrastructure details. Use consistent placeholders for hosts, clients,
and roles so their relationships remain understandable. Do not send Secrets,
credential files, raw tokens, full client exports, or browser HAR files.

## 1. Set your test target

Open a terminal on your work computer. Replace the two angle-bracket values.
The namespace and broker defaults below are for the test SKY workload; change
them if you are testing another workload.

```sh
export KUBE_CONTEXT='<approved-context>'
export WORKLOAD_NAMESPACE='artemis-int-sky'
export BROKER_CR='test-sky-artemis-artemis-ha'
export MANAGEMENT_HOST='<console-hostname-without-https>'

printf 'context=%s\nnamespace=%s\nbroker=%s\nhost=%s\n' \
  "$KUBE_CONTEXT" "$WORKLOAD_NAMESPACE" "$BROKER_CR" "$MANAGEMENT_HOST"
```

- [ ] Confirm these identify the intended test environment.
- [ ] Start a private local notes file outside the repository for your results.

## 2. Write down what working means

Copy this into your notes and fill it in:

```text
Environment/workload:
Date and time of test, including timezone:
Keycloak login required: yes / no
Local broker-admin login also required: yes / no
Viewer may:
Operator may (or write "no separate operator role"):
Administrator may:
Current problem or error:
```

Be specific about permissions: view queue statistics, browse message contents,
send messages, delete messages, create/delete queues, or change broker settings.
Do not assume that permission to view statistics includes message contents.

## 3. Record deployed versions

List broker containers, image tags, and actual image IDs:

```sh
kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  get pods --selector "ActiveMQArtemis=$BROKER_CR" \
  --output jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}{"  container="}{.name}{" image="}{.image}{"\n"}{end}{range .status.containerStatuses[*]}{"  imageID="}{.imageID}{"\n"}{end}{end}'
```

Also record these from the approved deployment UI, runtime information, or your
platform team:

```text
Artemis version:
Bundled Hawtio version (unknown is okay; do not infer it from Artemis version):
ArkMQ/operator version or image:
Keycloak version:
Argo application name and deployed Git revision:
```

Use the deployed revision shown in Argo; your local checkout may differ.

## 4. Check whether the console is reachable

```sh
for path in / /console /console/jolokia/version; do
  curl --max-time 10 --silent --show-error --output /dev/null \
    --write-out "$path: HTTP %{http_code}; redirect=%{redirect_url}\n" \
    "https://$MANAGEMENT_HOST$path"
done

kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  get pods --selector "ActiveMQArtemis=$BROKER_CR" --output wide

kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  get endpointslice \
  --selector "kubernetes.io/service-name=$BROKER_CR-console" --output wide

kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  describe ingress "$BROKER_CR-console"

kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  get networkpolicy "$BROKER_CR-allow" --output yaml
```

Record the outputs. A redirect or an unauthenticated `401`/`403` can be expected;
it does not establish that login works. Record timeouts, `404`, and `503` too.
Do not bypass certificate checks if curl reports a TLS error.

## 5. Collect the deployed OIDC configuration

```sh
kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  get configmap "$BROKER_CR-hawtio-oidc" \
  --output jsonpath='{.data.hawtio-oidc\.properties}{"\n"}'

kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  get activemqartemis "$BROKER_CR" \
  --output jsonpath='{range .spec.env[?(@.name=="JAVA_ARGS_APPEND")]}{.value}{"\n"}{end}'
```

Record whether:

- [ ] `provider` identifies the intended Keycloak realm.
- [ ] `client_id` matches the client you inspect in step 6.
- [ ] `redirect_uri` exactly matches `https://<console-hostname>/console`.
- [ ] Role values contain actual configured names rather than placeholders.
- [ ] JVM arguments include `-Dhawtio.oidcConfig=...` pointing to the OIDC file.

Review JVM arguments for sensitive values before sharing them. If the ConfigMap
is missing, record that error and continue.

## 6. Record the Keycloak client settings

Open the approved Keycloak administration console. Select the realm and client
from step 5. Inspect the existing settings without changing them during collection.
If you lack access, ask the identity team to fill in this block.

```text
Realm/issuer (sanitized):
Client ID (sanitized consistently with step 5):
Public or confidential client / Client authentication on or off:
Standard flow / authorization code flow enabled:
PKCE method or enforcement setting (S256 / other / unspecified):
Valid redirect URIs (preserve paths and wildcard structure):
Web origins:
Assigned default and optional client scopes:
Role mapper source (realm roles / client roles / other):
Role mapper output claim path:
Role mapper includes roles in access token / ID token / UserInfo:
Viewer role and test-user/group assignment:
Administrator role and test-user/group assignment:
Separate operator role and assignment, if applicable:
Does this client also serve the existing Classic console? yes / no / unknown
```

The repository intends test/nonprod to reuse the legacy preprod Hawtio client
and prod to reuse the production client. Record discrepancies. Changes to a
shared client need to account for its existing consumers.

If your identity team can inspect an actual test identity's claims using approved
local tooling, include only a sanitized role-claim fragment. Preserve the claim
structure and use placeholder role names, for example:

```json
{"realm_access":{"roles":["VIEWER_ROLE"]}}
```

Label which token or endpoint the fragment came from. Do not paste a raw token
into this document, the conversation, or an online decoder. If unavailable,
record `actual claim structure unknown`.

## 7. Try one browser login and capture the first failure

1. Open a fresh private browser window and its Developer Tools → Network tab.
2. Visit `https://<console-hostname>/console`.
3. Try Keycloak login with an approved test identity.
4. Record whether you reach Keycloak, return to Hawtio, and see broker data.
5. If it fails, record the first failing request's **method, path, HTTP status,
   and redacted response/error text**. Inspect Jolokia response bodies even when
   HTTP status is `200`; they can contain operation errors.
6. Record the test time and whether refreshing or navigating causes alternating
   successes and `403` responses. Record whether an ALB routing cookie is present;
   record its name only, never its value.
7. If local-admin login is required, close the private window and test it in a
   separate fresh session. Use that workload's approved broker credential source.

Do not send request bodies containing credentials, callback query strings or
fragments, cookies, authorization headers, or unredacted screenshots.

## 8. Collect matching broker logs

For each broker pod listed in step 3, replace the pod name and run:

```sh
export BROKER_POD='<broker-pod-name>'

kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  logs "$BROKER_POD" --all-containers=true --prefix=true --since=30m \
  | grep -Ei 'hawtio|jolokia|oidc|keycloak|jetty|8161|error|exception'
```

Keep relevant lines around your test time. Redact sensitive values before sharing.
An empty filtered result is useful to record too.

## 9. Record the effective security wiring, if available

This is the part the OIDC ConfigMap cannot prove. Ask the broker/platform team
for the following **non-secret configuration excerpts**, from the running
deployment or its verified generated configuration:

```text
Effective hawtio.realm:
Effective hawtio.roles (or hawtio.role):
JAAS login-module class names and control flags:
User-principal and role-principal class names:
How OIDC identities/roles reach Artemis management authorization:
Effective managementRBACEnabled setting:
Active management authorization mechanism and view/edit grants:
Relevant jolokia-access.xml restrictions, including CORS/Origin settings:
Issuer/JWKS reachable from broker network: confirmed / failed / unknown
```

Do not collect user/password files or dump all environment variables. File paths
vary by deployed image; if these details are unavailable, write `unknown`. We
can select precise follow-up commands once the image and versions are known.

## 10. Send back one sanitized evidence note

Use this outline and attach the sanitized command results beneath each section:

```text
1. Target environment and intended viewer/operator/admin permissions
2. Versions and deployed Git revision
3. Connectivity, pods, endpoints, ingress, and NetworkPolicy results
4. OIDC properties and relevant JVM arguments
5. Keycloak client settings and role-claim structure
6. Browser login result, first failure, and test timestamp
7. Matching broker logs
8. Effective security wiring, with unknowns marked
```

**First useful handoff:** steps 1–8 are enough to begin the implementation review.
Include whatever you have from step 9; missing details become targeted follow-ups.

## 11. After implementation: prove the integration works

Repository changes and local checks happen in the offline checkout. Deployment
and runtime acceptance happen through your approved work-computer process.
After the changes are deployed, record pass/fail for:

- [ ] Keycloak login returns to the intended console and loads broker data.
- [ ] Required local-admin login works in a separate session.
- [ ] Refreshing and navigating preserve the session without repeated `403`s.
- [ ] An unauthenticated identity cannot read protected data or mutate it.
- [ ] A viewer can perform approved reads and cannot perform mutations.
- [ ] An operator, if used, can perform only its explicitly approved actions.
- [ ] An administrator can perform the approved management actions.
- [ ] Authorization holds through both the UI and direct Jolokia requests;
      hidden buttons alone do not demonstrate enforcement.
- [ ] Logout ends access to protected operations for that browser session.

Use disposable test queues and synthetic messages for action tests. Exact direct
Jolokia requests will be chosen after the authentication mechanism and permission
matrix are confirmed. Record operation-level results as well as HTTP status.

For deeper troubleshooting, see [Hawtio access diagnosis](hawtio-access-diagnosis.md).
