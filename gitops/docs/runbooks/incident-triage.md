# Incident triage

The first objective is to protect safety: one active broker and no loss of
broker-acknowledged durable messages. At-least-once delivery permits duplicate
or redelivered in-flight messages.

## First five minutes

1. Record UTC time, approved context/cluster/namespace, current Argo revision,
   active/passive broker identities, ZooKeeper quorum, replication state, and
   client recovery duration. Do not record credentials or message bodies.
2. Check Argo `Synced`/`Healthy`, pod events, PVC attachment, node/zone
   placement, PDB status, broker active/passive state, replication connected /
   synchronized state, and ZooKeeper sessions/quorum.
3. Check queue depth, delivering/unacknowledged count, blocked producers,
   paging/disk, JVM heap/GC, file descriptors, and reconnect errors.
4. Freeze upgrades, rollouts, purge/move operations, and broker role reversals.
   Do not delete PVCs or force a second broker active.
5. Preserve structured logs, Kubernetes events, metrics, Argo history, and the
   latest validation reports.

## Pod cannot start: classify the failing stage first

A pod shown as `Pending`, `ContainerCreating`, or unready is not necessarily an
application failure. Read its events from oldest to newest and identify the last
completed stage: scheduling, volume attachment/mount, pod-sandbox networking,
image pull, container start, or application readiness.

On the authorized work computer, collect and classify one affected pod with:

```sh
./gitops/scripts/diagnose-pod-startup.sh \
  --context "$KUBE_CONTEXT" \
  --namespace "$WORKLOAD_NAMESPACE" \
  --pod "$POD_NAME" \
  > pod-startup-evidence.txt
```

The command is read-only. Exit `1` means it recognized a blocking startup
failure; the evidence file contains the classification and relevant cluster
state. Review and redact account IDs, instance IDs, IP addresses, hostnames,
and internal endpoints before moving the file outside the authorized team.

### AWS VPC CNI cannot assign a pod IP

An event containing all of the following is an EKS/platform-networking failure,
not a ZooKeeper process failure:

```text
FailedCreatePodSandBox
plugin type="aws-cni"
failed to assign an IP address to container
```

The ZooKeeper container has not started, so it has no useful application logs
yet. A successful EBS attachment does not contradict this diagnosis: storage
attachment precedes pod-sandbox network creation. Do not delete/restart the pod
or modify its probes as a first response; kubelet already retries sandbox
creation and those actions do not create IP capacity.

Use the diagnostic bundle to obtain the selected node and `aws-node` evidence.
Then use read-only AWS queries from the same approved work-computer session to
measure the node's subnet rather than guessing:

```sh
NODE_NAME='<node from pod-startup-evidence.txt>'
INSTANCE_ID=$(kubectl --context "$KUBE_CONTEXT" get node "$NODE_NAME" \
  -o 'jsonpath={.spec.providerID}')
INSTANCE_ID=${INSTANCE_ID##*/}
AWS_REGION=$(kubectl --context "$KUBE_CONTEXT" get node "$NODE_NAME" \
  -o 'jsonpath={.metadata.labels.topology\.kubernetes\.io/region}')
SUBNET_ID=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SubnetId' \
  --output text)
aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}' \
  --output table
```

Interpret the evidence in this order:

1. If subnet `AvailableIPs` is depleted or below the platform's scheduling
   headroom, the platform owner must add usable address capacity or place new
   capacity in a subnet with headroom.
2. If the subnet has headroom but failures concentrate on one node, compare its
   scheduled pod count, instance-type ENI/IP limit, and VPC CNI prefix/IP target
   settings with a healthy node.
3. If node capacity also has headroom, use the captured `aws-node` readiness and
   logs to resolve IAM, EC2 API reachability/throttling, add-on health, or IPAM
   reconciliation errors.
4. Treat stale node-local CNI state as a last hypothesis. Any restart, node
   recycle, CNI configuration change, subnet change, or prefix-delegation change
   is platform-owned and requires its approved change process.

After Kubernetes assigns the pod an IP and starts the container, continue with
ZooKeeper logs, readiness probes, peer DNS, and quorum checks. Preserve the
before/after events to prove which layer recovered.

### Passive broker is running but replication never starts

The chart deliberately keeps the passive broker out of ready client endpoints,
so one Running/not-ready peer is normal only after the HA relationship has
formed. The message `awaiting connection to a primary to start replication`
persisting indefinitely is not normal readiness behavior. Confirm that the
operator-generated ping and headless Services publish both pod addresses, then
verify broker-to-broker TCP reachability on JGroups discovery `7800`, JGroups
failure detection `7900`, and CORE replication `61616`. Under the chart's
default-deny policy, all three ports must be allowed in both directions between
pods in the same Workload Cell. A JGroups view containing only the local pod
means replication discovery has not completed.

## Decision paths

- **Two active brokers or coordination uncertainty:** isolate client traffic
  using the approved network controls, page the platform owner, and do not
  promote either side until ZooKeeper and journal ownership are proven.
- **ZooKeeper quorum loss:** expect no new activation; restore quorum one
  member at a time and verify exactly one active broker.
- **Pod sandbox / AWS VPC CNI failure:** the application container has not
  started. Keep broker safety controls unchanged and hand the captured node,
  subnet, `aws-node`, and event evidence to the EKS/platform-networking owner.
- **Replication disconnected:** keep the surviving active broker under the
  approved write policy, measure the acknowledged-send boundary, and do not
  fail back until synchronization is complete.
- **PVC/EBS issue:** preserve the volume and instance identity, inspect attach
  events, and use the backup/restore runbook if the volume cannot be recovered.
- **Credential, TLS, Keycloak, or Vault issue:** stop rotation/restarts, verify
  file-rendered secret paths and certificate validity without printing values,
  then restart one HA peer at a time.
- **Dead-letter growth:** preserve the affected per-source DLQ, record depth
  and original-address metadata without message bodies, stop bulk retry or
  purge actions, and isolate oversized or repeatedly failing messages into an
  approved triage queue before restoring normal traffic.

Use `gitops/scripts/eks-scenario.sh` for scoped evidence. It is dry-run by default;
destructive execution requires the exact context, cluster, and namespace
confirmation flags. The script cannot replace an incident commander or an
approved EKS change window.

## Exit criteria

Argo is healthy, exactly one broker is active, ZooKeeper has the intended
quorum, replication is synchronized, client service meets the measured target,
and the validation report has no missing acknowledged IDs. Attach a timeline,
root cause, impact, redelivery/duplicate accounting, recovery evidence, and
follow-up actions.
