# Install verification

Use this after Argo CD applies a new Artemis workload. Replace the uppercase
tokens with values supplied by the cluster platform; do not commit them.

> **Where to run live checks:** This repository checkout is an offline/test
> copy. Run every AWS, `kubectl`, Argo CD, and live EKS command in this runbook
> only from the authorized work computer. From this workspace, limit work to
> repository rendering, tests, and analysis of sanitized evidence copied from
> that computer. Do not start AWS SSO or attempt cluster access here.

## Preconditions

- Confirm the approved immutable image tags, chart artifact, and maintenance window.
- Confirm the target context, cluster, and namespace exactly.
- Verify the ApplicationSet controller and generated child Applications before
  checking workloads:

```sh
./gitops/scripts/verify-argocd-applicationset.sh \
  --context CONTEXT \
  --argocd-namespace ARGOCD_NAMESPACE \
  --environment test
```

  The verifier compares the selected local topology with live ApplicationSet,
  Application, AppProject, operator Deployment, `ActiveMQArtemis`, and
  StatefulSet health. It reports live Git revisions without assuming the work
  directory has Git metadata. Review any revision drift before promotion. For
  failure ownership and evidence commands, use the
  [broker reconciliation runbook](broker-reconciliation-debugging.md).
- Confirm Vault, storage class, ingress TLS, Prometheus, and Keycloak inputs
  exist in the environment repository.
- Run the destructive scenario harness once in its default dry-run mode:

```sh
./gitops/scripts/eks-scenario.sh --scenario clean-install \
  --context CONTEXT --cluster CLUSTER --namespace NAMESPACE
```

## Broker administrator credential handoff

Keycloak is not the source of the initial Artemis administrator credential.
The chart renders the shared, non-secret `spec.adminUser` configured by
`broker.adminUser`. Because `spec.adminPassword` remains absent, the ArkMQ
operator generates a separate password for each broker deployment in a Secret
named `BROKER_CR-credentials-secret`. The Secret keys remain `AMQ_USER` and
`AMQ_PASSWORD`; `AMQ_USER` should equal the configured shared username. This
repository intentionally contains no password.

Run the commands in this section only from the authorized work computer. First
confirm the context and inventory the generated credential Secrets without
reading their values:

```sh
kubectl config current-context
kubectl --context CONTEXT -n NAMESPACE get secrets \
  -o custom-columns=NAME:.metadata.name --no-headers \
  | awk '/-credentials-secret$/ {print $1}'
```

If the authorized identity has cluster-wide read access, inventory every
broker credential Secret in that cluster without reading values:

```sh
kubectl --context CONTEXT get secrets --all-namespaces \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name \
  --no-headers \
  | awk '$2 ~ /-credentials-secret$/ {print $1, $2}'
```

Confirm that `AMQ_USER` matches the configured shared username, then retrieve
one credential pair at a time in a private terminal by supplying the exact
workload namespace and broker CR:

```sh
kubectl --context CONTEXT -n NAMESPACE get secret \
  BROKER_CR-credentials-secret \
  -o jsonpath='{.data.AMQ_USER}' | base64 --decode; echo

kubectl --context CONTEXT -n NAMESPACE get secret \
  BROKER_CR-credentials-secret \
  -o jsonpath='{.data.AMQ_PASSWORD}' | base64 --decode; echo
```

For another broker pair, substitute its workload namespace and exact
`ActiveMQArtemis` resource name. Confirm the expected keys without revealing
their values before retrieval:

```sh
kubectl --context CONTEXT -n NAMESPACE get secret \
  BROKER_CR-credentials-secret \
  -o go-template='{{range $key, $value := .data}}{{$key}}{{"\n"}}{{end}}'
```

Record the shared username and deployment-specific password in the approved
Vault location using the security team's authorized UI or secret-input
workflow, then verify access and ownership. The username is non-secret and is
already declared in Git; never put the password in Markdown, Git, Helm values,
Argo parameters, tickets, chat, shell arguments, screenshots, or captured
command output. Do not bulk dump all namespaces. The Vault path should identify
the environment, workload namespace, and broker CR so each password can be
rotated independently.

This is a credential custody handoff, not completed runtime integration. The
chart's `vault.enabled` option remains off because the injected file is not yet
wired to the operator's `BROKER_CR-credentials-secret`. Copying the generated
value into Vault therefore does not rotate or replace the credential used by
the running broker.

## Verification

1. Check Argo application `Synced` and `Healthy`, including operator and CRD
   sync waves. A broker CR with `Valid=True` but `Deployed=False`,
   `Reason=ResourceError`, and an admission-webhook message about missing
   labels means the operator-generated resource failed policy even though the
   Argo-owned CR synced. Confirm the CR renders the required labels under both
   `deploymentPlan.labels` and the unscoped `resourceTemplates[0].labels`.
   A `RepeatedResourceWarning` naming the broker CR is not a pod failure: it
   means the effective child Application rendered the same group/kind/
   namespace/name twice. The chart's focused test checks the rendered inventory
   and produces one CR, so use the verifier to find a stale `spec.sources`
   entry or source drift in the generated child Application.
2. Check two broker pods are scheduled on distinct nodes and zones, each has a
   separate `ReadWriteOnce` PVC, and the PDB is respected. `Synced` alone means
   only that the declarative resources were applied. If no broker is scheduled,
   inspect pod events for an untolerated node taint before debugging ingress;
   the console Service will have no endpoint and the ALB will return 503 until
   an active broker is ready. Every broker environment overlay and the shared
   operator values intentionally tolerate only
   `eid-platform/node-lifecycle=ondemand:NoSchedule`.
3. Check readiness exposes only the active broker. Passive operation must not
   cause a liveness restart loop.
4. Check exactly one broker is active, the peer is passive, replication is
   connected and synchronized, and ZooKeeper has three voting members with
   quorum.
5. Check default-deny NetworkPolicies allow only broker messaging,
   replication, management, monitoring, DNS, Vault, Keycloak, and ZooKeeper
   paths.
6. Run every required protocol case from the
   [`acceptance plan`](../../tests/e2e/acceptance-plan.yaml) with the validation
   client. Use disposable destinations and credentials injected by the approved
   runner, not command-line secrets. Reports must satisfy their declared
   message-accounting claims.
7. Attach Argo, pod placement, active/passive, replication, ZooKeeper, policy,
   identity, and client reports to the change record.

Chart lint/render and unit tests are locally runnable. Scheduling, EBS,
ZooKeeper quorum, Argo health, Vault injection, Keycloak, and failover checks
require a real EKS test cluster.
