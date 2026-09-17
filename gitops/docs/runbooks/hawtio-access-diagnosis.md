# Hawtio access diagnosis

Use these commands only from the authorized work computer against the intended
Kubernetes context. They are read-only and do not print Secret objects. Review
and redact internal domains, addresses, CIDRs, client IDs, and role names before
sharing the output outside the authorized team.

## Set the target

Replace the context and management host. The remaining defaults identify the
enabled test SKY Workload Cell.

```sh
export KUBE_CONTEXT='<approved-context>'
export WORKLOAD_NAMESPACE='artemis-int-sky'
export BROKER_CR='test-sky-artemis-artemis-ha'
export MANAGEMENT_HOST='<real-hawtio-domain>'
```

Confirm that the variables identify the intended environment before continuing:

```sh
printf 'context=%s\nnamespace=%s\nbroker=%s\nhost=%s\n' \
  "$KUBE_CONTEXT" \
  "$WORKLOAD_NAMESPACE" \
  "$BROKER_CR" \
  "$MANAGEMENT_HOST"
```

## Check the external HTTP path

```sh
curl --max-time 10 --silent --show-error --output /dev/null \
  --write-out 'root: HTTP %{http_code}; redirect=%{redirect_url}\n' \
  "https://$MANAGEMENT_HOST/"

curl --max-time 10 --silent --show-error --output /dev/null \
  --write-out 'console: HTTP %{http_code}; redirect=%{redirect_url}\n' \
  "https://$MANAGEMENT_HOST/console"

curl --max-time 10 --silent --show-error --output /dev/null \
  --write-out 'jolokia: HTTP %{http_code}; redirect=%{redirect_url}\n' \
  "https://$MANAGEMENT_HOST/console/jolokia/version"
```

Interpretation:

- `200`, `302`, `401`, or `403` proves that the request reached the HTTP
  application boundary; continue with OIDC and authorization evidence.
- `503` usually means that the ALB has no healthy console target or the console
  Service has no usable endpoint.
- A timeout or connection failure points to DNS, ALB listener/security-group,
  routing, or NetworkPolicy admission.
- `404` points to the wrong host, Ingress rule, backend Service, or URL path.

## Check pods and console endpoints

```sh
kubectl --context "$KUBE_CONTEXT" \
  --namespace "$WORKLOAD_NAMESPACE" \
  get pods \
  --selector "ActiveMQArtemis=$BROKER_CR" \
  --output wide

kubectl --context "$KUBE_CONTEXT" \
  --namespace "$WORKLOAD_NAMESPACE" \
  get endpointslice \
  --selector "kubernetes.io/service-name=$BROKER_CR-console" \
  --output wide

kubectl --context "$KUBE_CONTEXT" \
  --namespace "$WORKLOAD_NAMESPACE" \
  describe service "$BROKER_CR-console"
```

The role-neutral readiness contract expects both healthy broker pods to become
ready and therefore eligible as console Service endpoints.

## Check Ingress and NetworkPolicy

```sh
kubectl --context "$KUBE_CONTEXT" \
  --namespace "$WORKLOAD_NAMESPACE" \
  get ingress "$BROKER_CR-console" \
  --output wide

kubectl --context "$KUBE_CONTEXT" \
  --namespace "$WORKLOAD_NAMESPACE" \
  describe ingress "$BROKER_CR-console"

kubectl --context "$KUBE_CONTEXT" \
  --namespace "$WORKLOAD_NAMESPACE" \
  get networkpolicy "$BROKER_CR-allow" \
  --output yaml
```

In the rendered NetworkPolicy, Hawtio port `8161` should have an ingress rule
with `ports` but no `from` field when
`networkPolicy.allowConsoleFromAllSources=true`. That means NetworkPolicy does
not apply a source CIDR to Hawtio. Rules created from `clientCidrs` must list
only enabled messaging acceptor ports and must not include `8161`.

Kubernetes NetworkPolicy operates at IP/port level and cannot distinguish
`/console` from another HTTP path on port `8161`. HTTP authentication and path
authorization remain the responsibility of Hawtio/Jolokia, Keycloak/OIDC, and
the shared ALB controls.

## Check rendered OIDC configuration

The ConfigMap contains no client secret, but its values identify internal
systems. Redact them before sharing.

```sh
kubectl --context "$KUBE_CONTEXT" \
  --namespace "$WORKLOAD_NAMESPACE" \
  get configmap "$BROKER_CR-hawtio-oidc" \
  --output jsonpath='{.data.hawtio-oidc\.properties}{"\n"}'

kubectl --context "$KUBE_CONTEXT" \
  --namespace "$WORKLOAD_NAMESPACE" \
  get activemqartemis "$BROKER_CR" \
  --output jsonpath='{range .spec.env[?(@.name=="JAVA_ARGS_APPEND")]}{.value}{"\n"}{end}'
```

Confirm that:

- `provider` names the real Keycloak issuer and realm;
- `client_id` is the approved Hawtio client;
- `redirect_uri` exactly equals `https://$MANAGEMENT_HOST/console`;
- viewer and administrator role names are resolved rather than placeholders;
- `JAVA_ARGS_APPEND` points to the mounted
  `$BROKER_CR-hawtio-oidc/hawtio-oidc.properties` file.

## Check broker web-console logs

Run this separately for each pod name returned above:

```sh
export BROKER_POD='<broker-pod-name>'

kubectl --context "$KUBE_CONTEXT" \
  --namespace "$WORKLOAD_NAMESPACE" \
  logs "$BROKER_POD" \
  --since=30m \
  | grep -Ei 'hawtio|jolokia|oidc|keycloak|jetty|8161|error|exception'
```

Do not retrieve or paste the broker credential Secret. If the filtered logs
contain tokens, authorization headers, account identifiers, internal URLs, or
usernames, replace them with `<REDACTED>` before sharing.

## Local administrator and Keycloak login together

Hawtio 4.6 introduced a login screen supporting both username/password and
OIDC authentication when both methods are configured. Confirm the Hawtio
version bundled in the deployed console; the broker version alone is not
evidence of the console version. See [Hawtio security documentation](https://hawt.io/docs/security.html#_multiple_login_methods).

The chart supplies `broker.adminUser` and, when `keycloak.enabled=true`, the
OIDC properties file. Supporting both login paths also requires the effective
Hawtio JAAS realm to retain the broker properties login module and its generated
user/role files. The local administrator must have a role accepted by Hawtio
and authorized for broker management. OIDC roles must likewise pass the console
login check and broker management authorization; listing roles in the OIDC
properties file does not itself grant JMX permissions. See
[Artemis management authorization](https://artemis.apache.org/components/artemis/documentation/latest/management.html).

Do not disable authentication or role checks to make either login work.
Use one login method per browser session, and log out before testing the other.

### Evidence for a login loop with HTTP 403

If login and `/console/user` succeed but subsequent requests alternate between
200 and 403, check session routing before resetting credentials. Both broker
pods are console targets, and broker HA replication does not establish shared
web sessions. The chart enables ALB duration-cookie stickiness for the console
target group using:

```yaml
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true,stickiness.type=lb_cookie,stickiness.lb_cookie.duration_seconds=86400
```

The 24-hour routing cookie does not extend Hawtio's login timeout. A pod restart
or unhealthy target can still require a fresh login. Do not replace this with
Kubernetes Service `sessionAffinity`: ALB IP targets route directly to pods.
See [AWS Load Balancer Controller annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.11/guide/ingress/annotations/#target-group-attributes).

After the chart change is deployed from the authorized work system:

1. Use the read-only Ingress inspection above to confirm the annotation is
   present, and check controller reconciliation events for errors.
2. Start a fresh browser session, log in, and confirm an ALB stickiness cookie
   is set and sent on subsequent requests. Check cookie names only; do not
   share values. The Jetty session cookie alone does not prove ALB stickiness.
3. Repeat page navigation and management reads. Confirm `/console/user` remains
   authenticated and inspect Jolokia response bodies as well as HTTP status:
   a Jolokia HTTP 200 response may still contain operation-level errors.
4. If failures persist, compare a successful and failed request's method,
   operation, Origin, and redacted response. Alternating HTTP status alone
   does not prove requests reached different pods.

For local admin login, use the password belonging to this Workload Cell's
operator-managed credential Secret. The chart shares the configured admin
username but does not set a shared admin password. Do not substitute Keycloak
credentials or a password from another Workload Cell.

The chart's readiness probe authenticates to Jolokia with `AMQ_USER` and
`AMQ_PASSWORD` and `Origin: http://localhost`. If that exact probe is deployed
and passing, it demonstrates that those credentials can perform its management
read locally. It does not validate the password typed into the browser or the
external HTTPS Origin. The default Ingress explicitly uses an HTTP backend.

A `/console/user` 403 before login can be the normal unauthenticated response.
Repeated `/console/jolokia` 403 responses after login require separate evidence.
A `/console/preset-connections` 404 does not by itself identify an authentication
failure. Capture the login request status and the first failing Jolokia
response body in browser Developer Tools, redacting cookies, tokens, credentials,
and authorization headers before sharing. Record which login method was used.

From the approved work computer, compare an authenticated read with and without
the browser Origin header. These commands prompt for the password rather than
putting it in shell history. Set `BROKER_ADMIN_USER` to the configured username.
Use the target variables defined above.

```sh
export BROKER_ADMIN_USER='<configured-admin-username>'
curl --max-time 10 --silent --show-error \
  --user "$BROKER_ADMIN_USER" \
  --write-out '\nHTTP %{http_code}\n' \
  "https://$MANAGEMENT_HOST/console/jolokia/version"

curl --max-time 10 --silent --show-error \
  --user "$BROKER_ADMIN_USER" \
  --header "Origin: https://$MANAGEMENT_HOST" \
  --write-out '\nHTTP %{http_code}\n' \
  "https://$MANAGEMENT_HOST/console/jolokia/version"
```

If only the Origin-bearing request fails, inspect the effective
`jolokia-access.xml` and TLS termination path. Artemis documents rejection when
an HTTPS Origin reaches Jolokia over HTTP. This comparison does not test browser
session persistence or OIDC token validation. See
[Artemis console security](https://artemis.apache.org/components/artemis/documentation/latest/management-console.html).

For unresolved failures, collect the deployed console/Hawtio version, effective
`hawtio.realm`, `hawtio.roles` (or legacy `hawtio.role`), JAAS module names and
control flags, and the filtered logs above. Do not share user/password files.
These distinguish authentication, role authorization, and Jolokia policy
failures before changing the chart's security configuration.
