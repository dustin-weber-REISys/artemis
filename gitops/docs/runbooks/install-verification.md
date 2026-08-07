# Install verification

Use this after Argo CD applies a new Artemis workload. Replace the uppercase
tokens with values supplied by the cluster platform; do not commit them.

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
  The verifier also confirms that each enabled broker pair's exact local
  destination is present in the `messaging-platform` AppProject and that the
  generated Application has no `InvalidSpecError`. Confirm the cluster's Argo
  CD installation enables an available `argocd-applicationset-controller`
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
   sync waves.
2. Check two broker pods are scheduled on distinct nodes and zones, each has a
   separate `ReadWriteOnce` PVC, and the PDB is respected.
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
