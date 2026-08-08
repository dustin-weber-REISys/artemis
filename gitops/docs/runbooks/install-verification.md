# Install verification

Use this after Argo CD applies a new Artemis workload. Replace the uppercase
tokens with values supplied by the cluster platform; do not commit them.

> **Where to run live checks:** This repository checkout is an offline/test
> copy. Run every AWS, `kubectl`, Argo CD, and live EKS command in this runbook
> only from the authorized work computer. From this workspace, limit work to
> repository rendering, tests, and analysis of sanitized evidence copied from
> that computer. Do not start AWS SSO or attempt cluster access here.

## Preconditions

- Confirm the approved image/chart digests and the maintenance window.
- Confirm the target context, cluster, and namespace exactly.
- Verify the ApplicationSet controller and generated child Applications before
  checking workloads:

```sh
./gitops/scripts/verify-argocd-applicationset.sh \
  --context CONTEXT \
  --argocd-namespace ARGOCD_NAMESPACE \
  --environment test
```

  A synced ApplicationSet with no status conditions has not been reconciled.
  The verifier also confirms that the ArkMQ operator Deployment has an
  available replica, the exact on-demand-node toleration, cluster-wide watch
  scope, and the read/write RBAC needed to generate broker resources. For each
  enabled broker pair, it verifies the local destination, a single Git/Helm
  source, the source fields owned by the ApplicationSet, no `InvalidSpecError`
  or `RepeatedResourceWarning`, exactly the declared Helm parameter names, the
  `ActiveMQArtemis` reconciliation conditions, and the expected operator-owned
  StatefulSet. A CR with no conditions identifies an operator observation
  failure; `Valid=False` or `Deployed=False` preserves the operator's reason
  and message; a missing `-ss` StatefulSet proves reconciliation never reached
  workload creation.
  This catches duplicate sources as well as stale or UI-added overrides such
  as `networkPolicy.*Selector={}`; Helm interprets that syntax as an empty
  array, not the selector object required by the chart.
  Check the owning ApplicationSet first. If it declares the override, sync the
  root Application to the approved Git revision and reconcile the
  ApplicationSet; deleting generated child Applications only recreates the
  same invalid parameters. If only the child differs, reconcile its owning
  ApplicationSet. Do not weaken the values schema. Confirm the cluster's Argo CD
  installation enables an available `argocd-applicationset-controller`
  Deployment in the same namespace as the ApplicationSet. Enabling a topology
  entry cannot create a valid child Application until the controller is
  running and the AppProject permits its workload namespace.
- Confirm Vault, storage class, ingress TLS, Prometheus, and Keycloak inputs
  exist in the environment repository.
- Run the destructive scenario harness once in its default dry-run mode:

```sh
./gitops/scripts/eks-scenario.sh --scenario clean-install \
  --context CONTEXT --cluster CLUSTER --namespace NAMESPACE
```

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
