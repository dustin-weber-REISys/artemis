# Install verification

Use this after Argo CD applies a new Artemis workload. Replace the uppercase
tokens with values supplied by the cluster platform; do not commit them.

## Preconditions

- Confirm the approved image/chart digests and the maintenance window.
- Confirm the target context, cluster, and namespace exactly.
- Confirm Vault, storage class, ingress TLS, Prometheus, and Keycloak inputs
  exist in the environment repository.
- Run the destructive scenario harness once in its default dry-run mode:

```sh
./scripts/eks-scenario.sh --scenario clean-install \
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
6. Run both protocol smoke tests with the validation client. Use a disposable
   queue and credentials injected by the job, not command-line secrets.

```sh
make test
java -cp 'client.jar:lib/*' org.example.artemis.validation.Main send \
  --protocol openwire --url OPENWIRE_URL --destination VALIDATION_QUEUE \
  --count 1000 --output send-openwire.json
java -cp 'client.jar:lib/*' org.example.artemis.validation.Main consume \
  --protocol openwire --url OPENWIRE_URL --destination VALIDATION_QUEUE \
  --expected-count 1000 --output consume-openwire.json
```

Repeat the send/consume pair with `--protocol amqp` and the AMQP URL. The
reports must show `status: PASS`, no missing or unexpected sequences, and
`rpoStatus: PASS`. Attach Argo, pod placement, active/passive, replication,
ZooKeeper, policy, and client reports to the change record.

Chart lint/render and unit tests are locally runnable. Scheduling, EBS,
ZooKeeper quorum, Argo health, Vault injection, Keycloak, and failover checks
require a real EKS test cluster.
