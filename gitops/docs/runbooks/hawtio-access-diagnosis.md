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
