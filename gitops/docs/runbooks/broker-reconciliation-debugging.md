# Broker reconciliation debugging

Use this runbook when an Argo CD Application contains an
`ActiveMQArtemis` resource but the ArkMQ operator has not produced a healthy
StatefulSet and broker pods.

Run Kubernetes commands only from the authorized work computer. This checkout
is an offline/test copy and must not be used to contact a live cluster. Every
cluster command in this runbook is read-only. Do not capture Secret contents,
broker credentials, tokens, or message bodies.

## Understand the ownership boundary

Argo CD and the operator prove different things:

1. The ApplicationSet creates one Argo CD Application per enabled broker pair.
2. Argo CD renders the Helm chart and applies the `ActiveMQArtemis` custom
   resource and chart-owned resources.
3. The ArkMQ operator observes the custom resource and creates the broker
   StatefulSet and pods.

A Synced Argo CD Application therefore does not prove that the operator
successfully reconciled the broker.

## Standard workflow

### 1. Validate the repository copy

Run local validation before investigating the cluster. This distinguishes a
repository defect from live-state drift.

```sh
git status --short --untracked-files=all
make validate-static
make validate-topology
make -C gitops test-verify-applicationset
```

If these checks fail, fix the repository first. Do not use a cluster refresh to
hide a local chart, topology, or generated-manifest error.

### 2. Check live health

On the authorized work computer, first verify the selected context explicitly:

```sh
CONTEXT=$(kubectl config current-context)
printf 'Selected context: %s\n' "$CONTEXT"
```

Then run the health check with the correct Argo CD namespace and environment:

```sh
./gitops/scripts/verify-argocd-applicationset.sh \
  --context "$CONTEXT" \
  --argocd-namespace ARGOCD_NAMESPACE \
  --environment test
```

Replace `test` with `nonprod` or `prod` as appropriate. The verifier checks:

- ApplicationSet controller availability and reconciliation;
- operator Application sync and health;
- operator Deployment availability;
- AppProject destination authorization;
- child Application ownership, sync, health, and blocking conditions;
- broker custom-resource reconciliation conditions; and
- expected StatefulSet readiness.

The verifier reports the Git revision reconciled by each Application but does
not compare it with local `HEAD`. Different revisions are normal when the work
computer has not checked out the exact commit deployed by Argo CD.

Stop at the first failed ownership boundary. Investigating pods cannot explain
a missing StatefulSet, and changing the chart cannot repair an unavailable
operator.

### 3. Collect a reusable evidence bundle

When the health check fails, collect evidence before requesting a refresh,
restart, or sync:

```sh
./gitops/scripts/collect-artemis-evidence.sh \
  --context "$CONTEXT" \
  --argocd-namespace ARGOCD_NAMESPACE \
  --environment test \
  > artemis-evidence-"$(date -u +%Y%m%dT%H%M%SZ)".txt
```

The collector continues after individual read failures so one authorization
problem does not discard the rest of the evidence. It includes Application
state, the operator Deployment and recent logs, broker custom resources,
StatefulSets, pods, PVCs, Services, ConfigMaps, and namespace events. It does
not request Secret objects.

Review the file before sharing it outside the authorized team; logs and
manifests can still contain environment-specific names and endpoints.

## Interpret the first failure

| Failed boundary | Likely owner | Next check |
| --- | --- | --- |
| ApplicationSet controller unavailable | Argo CD platform | Controller Deployment status and events |
| ApplicationSet reports `ErrorOccurred=True` | Git topology or ApplicationSet template | Local topology validation and controller message |
| Operator Application OutOfSync or Degraded | Operator chart or Argo CD | Application conditions and operator Deployment |
| Operator Deployment unavailable | Operator platform | Pod status, events, image pull, scheduling, and logs |
| AppProject rejects a namespace | Argo CD project configuration | Environment bootstrap destination list |
| Child Application missing | ApplicationSet inputs | Enabled topology row and ApplicationSet conditions |
| `InvalidSpecError` | Child Application template | Destination and source configuration |
| `RepeatedResourceWarning` | Duplicate rendered identity | Rendered chart resources and Application sources |
| Broker CR has no status | Operator watch scope or RBAC | Operator logs and authorization checks |
| `Valid=False` | Broker custom-resource configuration | Condition reason/message and rendered manifest |
| `Deployed=False` | Generated-resource admission or API failure | Operator logs and namespace events |
| StatefulSet missing | Operator reconciliation | CR conditions, operator logs, and admission events |
| StatefulSet not ready | Workload runtime | Pod status, events, probes, PVCs, and scheduling |

## Focused follow-up commands

Use these only after the standard health check and evidence collection identify
the failed boundary. Set explicit values rather than relying on an implicit
namespace.

```sh
PLATFORM_NAMESPACE=PLATFORM_NAMESPACE
WORKLOAD_NAMESPACE=WORKLOAD_NAMESPACE
BROKER_CR=BROKER_CR
OPERATOR_SERVICE_ACCOUNT=activemq-artemis-controller-manager
```

### Operator watch scope and authorization

```sh
kubectl --context "$CONTEXT" -n "$PLATFORM_NAMESPACE" get deployment \
  activemq-artemis-controller-manager-v2 \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].env[?(@.name=="WATCH_NAMESPACE")].value}{"\n"}'

kubectl --context "$CONTEXT" auth can-i list \
  activemqartemises.broker.amq.io --all-namespaces \
  --as="system:serviceaccount:$PLATFORM_NAMESPACE:$OPERATOR_SERVICE_ACCOUNT"

kubectl --context "$CONTEXT" auth can-i create statefulsets.apps \
  -n "$WORKLOAD_NAMESPACE" \
  --as="system:serviceaccount:$PLATFORM_NAMESPACE:$OPERATOR_SERVICE_ACCOUNT"
```

Cluster-wide operation requires an empty `WATCH_NAMESPACE`, permission to
list/watch broker resources across namespaces, and permission to create the
generated resources in each workload namespace.

### Broker reconciliation status

```sh
kubectl --context "$CONTEXT" -n "$WORKLOAD_NAMESPACE" get \
  activemqartemis "$BROKER_CR" -o json | yq '{
    generation: .metadata.generation,
    labels: (.metadata.labels // {}),
    deploymentPlanLabels: (.spec.deploymentPlan.labels // {}),
    resourceTemplates: (.spec.resourceTemplates // []),
    conditions: (.status.conditions // [])
  }'
```

Compare `observedGeneration` in the conditions with `metadata.generation`.
Older conditions can describe an earlier manifest. Preserve the complete
reason and message for any current `Valid=False` or `Deployed=False` condition.

### Generated resource and pod status

```sh
kubectl --context "$CONTEXT" -n "$WORKLOAD_NAMESPACE" get \
  statefulset "$BROKER_CR-ss" -o wide
kubectl --context "$CONTEXT" -n "$WORKLOAD_NAMESPACE" describe \
  statefulset "$BROKER_CR-ss"
kubectl --context "$CONTEXT" -n "$WORKLOAD_NAMESPACE" get pods,pvc -o wide
kubectl --context "$CONTEXT" -n "$WORKLOAD_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp
```

For admission failures, fix the repository-owned broker specification or
resource template that causes the operator to generate an invalid resource.
Do not weaken policy as an incident workaround.

For a created but unready StatefulSet, investigate the pod's scheduling,
volume, image-pull, startup, and readiness events in that order. Container logs
are useful only after the container starts.

## Git revision and manifest drift

Record these independently:

```sh
git rev-parse HEAD
kubectl --context "$CONTEXT" -n ARGOCD_NAMESPACE get application APPLICATION \
  -o jsonpath='{.status.sync.revision}{"\n"}'
```

A mismatch means the workstation and cluster are examining different commits;
it is evidence, not a health failure. Check out the reconciled revision or
compare the two commits before drawing conclusions from a local Helm render.

If the revisions match but the live custom resource differs from a clean local
render, preserve the Application YAML and live resource first. Then use the
authorized Argo CD process to inspect generated manifests and request a hard
refresh if appropriate. A refresh is not a substitute for committing a fix.

## Completion criteria

An incident is resolved only when all of the following are true:

- local repository validation passes;
- the live verifier reports `PASS`;
- Applications are Synced and Healthy at the intended revision;
- broker conditions observe the current generation without a current
  `Valid=False` or `Deployed=False` result;
- each expected StatefulSet exists with all desired replicas ready; and
- the evidence contains no unresolved admission, scheduling, image-pull,
  volume, startup, or readiness errors.

Record the reconciled revision, verifier output, and evidence-bundle path in the
change or incident record. Never include credentials or Secret data.
