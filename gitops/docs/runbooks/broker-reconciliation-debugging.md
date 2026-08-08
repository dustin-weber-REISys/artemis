# Broker reconciliation debugging

Use this runbook when Argo CD shows an `ActiveMQArtemis` resource and the
chart-owned Services, but the ArkMQ operator does not create a StatefulSet or
broker pods. These commands use the current kubeconfig context; select and
verify that context separately before starting.

All Kubernetes commands below are read-only. They do not sync Applications,
patch resources, restart workloads, or delete anything. Do not capture Secret
contents, broker credentials, tokens, or message bodies in the evidence.

Run live-cluster commands only from the authorized work computer. This
repository checkout is an offline/test copy and must not be used to access the
real cluster.

## Set the resource names

Set these once for the affected broker pair. Replace the example values with
the real namespaces and names.

```sh
ARGOCD_NAMESPACE=argocd
PLATFORM_NAMESPACE=artemis-platform
WORKLOAD_NAMESPACE=artemis-int-sky

APPLICATION=test-sky-artemis
APPLICATIONSET=test-artemis-workloads
OPERATOR_APPLICATION=test-arkmq-operator
BROKER_CR=test-sky-artemis-artemis-ha

OPERATOR_DEPLOYMENT=activemq-artemis-controller-manager
OPERATOR_SERVICE_ACCOUNT=activemq-artemis-controller-manager
```

Confirm the current context and resolved variables before collecting evidence:

```sh
kubectl config current-context
printf 'Argo CD namespace: %s\nPlatform namespace: %s\nWorkload namespace: %s\nApplication: %s\nBroker CR: %s\n' \
  "$ARGOCD_NAMESPACE" \
  "$PLATFORM_NAMESPACE" \
  "$WORKLOAD_NAMESPACE" \
  "$APPLICATION" \
  "$BROKER_CR"
```

## Operator Deployment immutable-selector sync failure

Use this focused sequence when Argo CD reports
`spec.selector ... field is immutable`. Existing enterprise-labelled installs
store an eight-label selector: the fixed operator pair, Helm name and instance,
and `app`, `contact`, `env`, and `fismaid`. The chart must reproduce that exact
map; reducing it to only the fixed pair is still an immutable-field change.
This sequence confirms the Application identity, desired revision, live
selector, and rendered compatibility selector without deleting the running
operator.

Set the expected environment and Helm release to the same identity as the
operator Application. For nonproduction, for example:

```sh
# Run this section from the repository root, not from Downloads or another
# directory. Replace the example path with the work-computer checkout.
cd /path/to/elis-artemis
git rev-parse --show-toplevel

EXPECTED_ENVIRONMENT=nonprod
EXPECTED_RELEASE=nonprod-arkmq-operator
EXPECTED_REVISION=$(git rev-parse HEAD)

printf 'application=%s environment=%s release=%s localRevision=%s\n' \
  "$OPERATOR_APPLICATION" \
  "$EXPECTED_ENVIRONMENT" \
  "$EXPECTED_RELEASE" \
  "$EXPECTED_REVISION"
```

### 1. Compare the configured source, reconciled source, and latest operation

The Application name, environment parameter, and Helm release must describe
the same environment. For example, `test-arkmq-operator` must not reconcile a
`nonprod-arkmq-operator` release with `env=nonprod`. The sync revision must
equal the commit containing the compatibility selector before later cluster
evidence can validate it.

```sh
kubectl -n "$ARGOCD_NAMESPACE" get application "$OPERATOR_APPLICATION" -o json |
  yq '{
    "application": .metadata.name,
    "configuredSource": {
      "path": .spec.source.path,
      "targetRevision": .spec.source.targetRevision,
      "releaseName": .spec.source.helm.releaseName,
      "environment": ([
        .spec.source.helm.parameters[]? |
        select(.name == "global.requiredLabels.env") |
        .value
      ][0] // "")
    },
    "reconciledSource": (.status.sync.comparedTo.source // {}),
    "sync": (.status.sync // {}),
    "health": (.status.health // {}),
    "conditions": (.status.conditions // []),
    "operation": {
      "phase": (.status.operationState.phase // ""),
      "message": (.status.operationState.message // ""),
      "startedAt": (.status.operationState.startedAt // ""),
      "finishedAt": (.status.operationState.finishedAt // ""),
      "resources": [
        .status.operationState.syncResult.resources[]? |
        select(
          .name == "activemq-artemis-controller-manager" or
          .name == "activemq-artemis-operator-role" or
          .name == "activemq-artemis-operator-rolebinding" or
          .name == "activemq-artemis-leader-election-role" or
          .name == "activemq-artemis-leader-election-rolebinding"
        ) |
        {
          "group": .group,
          "kind": .kind,
          "namespace": .namespace,
          "name": .name,
          "status": .status,
          "hookPhase": .hookPhase,
          "message": .message
        }
      ]
    }
  }'
```

### 2. Check whether Argo currently tracks the expected resources

```sh
kubectl -n "$ARGOCD_NAMESPACE" get application "$OPERATOR_APPLICATION" -o json |
  yq -r '.status.resources[]? |
    select(
      .name == "activemq-artemis-controller-manager" or
      .name == "activemq-artemis-operator-role" or
      .name == "activemq-artemis-operator-rolebinding" or
      .name == "activemq-artemis-leader-election-role" or
      .name == "activemq-artemis-leader-election-rolebinding"
    ) |
    [
      (.group // ""),
      .kind,
      (.namespace // ""),
      .name,
      (.status // ""),
      (.health.status // ""),
      ((.requiresPruning // false) | tostring)
    ] | @tsv'
```

An `OutOfSync` Deployment row plus an operation message containing
`spec.selector ... field is immutable` means the desired and live selector
maps differ. An absent Deployment row means Argo's current manifest cache did
not render the Deployment.

### 3. Check live operator resources without stopping on `NotFound`

```sh
kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o yaml
kubectl -n "$PLATFORM_NAMESPACE" get serviceaccount "$OPERATOR_SERVICE_ACCOUNT" -o yaml
kubectl -n "$PLATFORM_NAMESPACE" get poddisruptionbudget "$OPERATOR_DEPLOYMENT" -o yaml

kubectl -n "$PLATFORM_NAMESPACE" get replicasets,pods \
  -l name=activemq-artemis-operator \
  -o wide

kubectl get clusterrole activemq-artemis-operator-role -o yaml
kubectl get clusterrolebinding activemq-artemis-operator-rolebinding -o yaml
```

Preserve every `NotFound` response. Do not delete or recreate the Deployment
manually while Argo owns the Application; the compatibility render is designed
to update it in place.

### 4. Collect namespace-level create and admission failures

```sh
kubectl -n "$PLATFORM_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp |
  tail -150 |
  grep -Ei \
    'activemq-artemis|failedcreate|denied|forbidden|admission|gatekeeper|selector|image|serviceaccount'
```

If the filtered command prints nothing, preserve the unfiltered last 50 events:

```sh
kubectl -n "$PLATFORM_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp |
  tail -50
```

### 5. Compare the live and locally rendered selectors

The `helm` commands build the file-based dependency and render only from the
local checkout. The `kubectl get` is read-only and retrieves only the live
Deployment selector; none of these commands expose Secret data.

```sh
helm dependency build gitops/charts/arkmq-operator

kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o json |
  yq '.spec.selector.matchLabels'

helm template "$EXPECTED_RELEASE" gitops/charts/arkmq-operator \
  --namespace "$PLATFORM_NAMESPACE" \
  --set-string "global.requiredLabels.env=$EXPECTED_ENVIRONMENT" |
  yq 'select(
    .kind == "Deployment" and
    .metadata.name == "activemq-artemis-controller-manager"
  ) | {
    "name": .metadata.name,
    "labels": .metadata.labels,
    "selector": .spec.selector.matchLabels,
    "podLabels": .spec.template.metadata.labels,
    "serviceAccountName": .spec.template.spec.serviceAccountName
  }'
```

The live and rendered selector maps must be identical and contain exactly eight
labels: `control-plane`, `name`, `app.kubernetes.io/name`,
`app.kubernetes.io/instance`, `app`, `contact`, `env`, and `fismaid`. The pod
labels must contain the same eight labels and may contain additional metadata
labels. If the maps differ, first verify the Application/release/environment
identity and local Git revision; do not force or replace the Deployment.

## Priority evidence: run these first

For an operator that is running but logging cluster-scoped `forbidden` errors,
start with the three checks below. They distinguish an operator Application
sync failure, a missing or incorrect RBAC object, and an ineffective binding.
All three checks are read-only. Share their complete output before collecting
the longer evidence bundle later in this runbook.

### A. Check the operator Application and its RBAC resources

```sh
kubectl -n "$ARGOCD_NAMESPACE" get application "$OPERATOR_APPLICATION" -o json |
  yq '{
    "sync": .status.sync,
    "health": .status.health,
    "conditions": (.status.conditions // []),
    "operationState": (.status.operationState // {}),
    "rbacResources": [
      .status.resources[]? |
      select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding")
    ]
  }'
```

### B. Check the live ClusterRole and ClusterRoleBinding

The binding subject namespace must equal `$PLATFORM_NAMESPACE`, and its
`roleRef` must name `activemq-artemis-operator-role`.

```sh
kubectl get clusterrolebinding activemq-artemis-operator-rolebinding -o json |
  yq '{"roleRef": .roleRef, "subjects": .subjects}'

kubectl get clusterrole activemq-artemis-operator-role -o json |
  yq '.rules[] |
    select(
      (.resources | contains(["activemqartemises"])) or
      (.resources | contains(["configmaps"])) or
      (.resources | contains(["statefulsets"]))
    )'
```

If either `kubectl get` returns `NotFound`, preserve that output; it directly
identifies the missing RBAC object.

### C. Test the operator's effective cluster-wide permissions

```sh
OPERATOR_ID="system:serviceaccount:$PLATFORM_NAMESPACE:$OPERATOR_SERVICE_ACCOUNT"

for verb in list watch; do
  for resource in \
    activemqartemises.broker.amq.io \
    configmaps \
    statefulsets.apps; do
    printf '%-7s %-45s ' "$verb" "$resource"
    kubectl auth can-i "$verb" "$resource" \
      --all-namespaces \
      --as "$OPERATOR_ID"
  done
done
```

Every result must be `yes`. A `no` confirms that the operator cannot start the
cluster-wide informers required by its empty `WATCH_NAMESPACE`. If the command
reports that the caller cannot impersonate the service account, preserve that
error and have an authorized cluster administrator run check C.

## 1. Check the effective Argo CD Application

Show synchronization, health, revision, and application conditions:

```sh
kubectl -n "$ARGOCD_NAMESPACE" get application "$APPLICATION" -o json |
  yq '{
    "application": .metadata.name,
    "generation": .metadata.generation,
    "destination": .spec.destination,
    "sync": .status.sync,
    "health": .status.health,
    "conditions": (.status.conditions // [])
  }'
```

Confirm that the generated child Application has one `spec.source`, not a
stale or UI-added `spec.sources` list:

```sh
kubectl -n "$ARGOCD_NAMESPACE" get application "$APPLICATION" -o json |
  yq '{
    "ownerReferences": .metadata.ownerReferences,
    "source": .spec.source,
    "sources": (.spec.sources // []),
    "sourceCount": (.spec.sources // [] | length),
    "parameters": (.spec.source.helm.parameters // [])
  }'
```

Inspect the owning ApplicationSet template and reconciliation conditions:

```sh
kubectl -n "$ARGOCD_NAMESPACE" get applicationset "$APPLICATIONSET" -o json |
  yq '{
    "generation": .metadata.generation,
    "templateSource": .spec.template.spec.source,
    "templateSources": (.spec.template.spec.sources // []),
    "conditions": (.status.conditions // [])
  }'
```

Print only warning and error conditions from the child Application:

```sh
kubectl -n "$ARGOCD_NAMESPACE" get application "$APPLICATION" -o json |
  yq -r '.status.conditions[]? |
    select(.type == "RepeatedResourceWarning" or .type == "InvalidSpecError") |
    [.type, .message] | @tsv'
```

## 2. Confirm that the ArkMQ operator is running

First inspect the operator Application itself. A running Deployment does not
prove that its cluster-scoped RBAC resources synced successfully:

```sh
kubectl -n "$ARGOCD_NAMESPACE" get application "$OPERATOR_APPLICATION" -o json |
  yq '{
    "sync": .status.sync,
    "health": .status.health,
    "conditions": (.status.conditions // []),
    "operationState": (.status.operationState // {})
  }'
```

Check the operator Deployment and pods:

```sh
kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o wide

kubectl -n "$PLATFORM_NAMESPACE" get pods \
  -l name=activemq-artemis-operator \
  -o wide
```

Show desired, updated, ready, and available replicas:

```sh
kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o json |
  yq '{
    "generation": .metadata.generation,
    "observedGeneration": .status.observedGeneration,
    "desired": .spec.replicas,
    "updated": (.status.updatedReplicas // 0),
    "ready": (.status.readyReplicas // 0),
    "available": (.status.availableReplicas // 0),
    "unavailable": (.status.unavailableReplicas // 0),
    "conditions": (.status.conditions // [])
  }'
```

Confirm the watched namespaces and operator tolerations rendered into the live
Deployment. An empty `WATCH_NAMESPACE` is the cluster-wide setting for this
chart.

```sh
kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o json |
  yq -r '.spec.template.spec.containers[] |
    select(.name == "manager") |
    .env[] |
    select(.name == "WATCH_NAMESPACE") |
    "WATCH_NAMESPACE=" + (.value // "")'

kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o json |
  yq '.spec.template.spec.tolerations // []'
```

Show recent operator events and logs. The log filter targets reconciliation,
authorization, image resolution, and admission-policy errors.

```sh
kubectl -n "$PLATFORM_NAMESPACE" events \
  --for "deployment/$OPERATOR_DEPLOYMENT" \
  --types Warning,Normal

kubectl -n "$PLATFORM_NAMESPACE" logs \
  -l name=activemq-artemis-operator \
  --all-containers=true \
  --prefix=true \
  --tail=500 |
  grep -Ei "$BROKER_CR|error|forbidden|denied|failed|resourceerror|watch|image"
```

If `kubectl events` is unavailable in the installed client, use:

```sh
kubectl -n "$PLATFORM_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp |
  tail -100
```

## 3. Read the broker CR reconciliation status

The CR status is the most important discriminator. Argo CD can report a
successful sync even when the operator cannot create its generated resources.

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get activemqartemis "$BROKER_CR" -o json |
  yq '{
    "name": .metadata.name,
    "namespace": .metadata.namespace,
    "generation": .metadata.generation,
    "resourceVersion": .metadata.resourceVersion,
    "deletionTimestamp": .metadata.deletionTimestamp,
    "finalizers": (.metadata.finalizers // []),
    "status": (.status // {})
  }'
```

Print the conditions in a compact form suitable for pasting into a ticket or
debugging session:

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get activemqartemis "$BROKER_CR" \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.observedGeneration}{"\t"}{.message}{"\n"}{end}'
```

Show the desired generation beside every observed generation:

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get activemqartemis "$BROKER_CR" -o json |
  yq -r '.metadata.generation as $generation |
    "desiredGeneration=" + ($generation | tostring),
    (.status.conditions[]? |
      "condition=" + .type +
      " status=" + .status +
      " observedGeneration=" + ((.observedGeneration // 0) | tostring) +
      " reason=" + .reason)'
```

## 4. Check for operator-generated resources

The expected StatefulSet name is the broker CR name with `-ss` appended.

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get statefulset "$BROKER_CR-ss" -o wide
```

List resources carrying the operator's broker identity label:

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get \
  statefulsets,pods,persistentvolumeclaims,services,secrets,configmaps \
  -l "ActiveMQArtemis=$BROKER_CR" \
  -o wide
```

Also list by the operator's application label:

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get \
  statefulsets,pods,persistentvolumeclaims,services,secrets,configmaps \
  -l "application=$BROKER_CR-app" \
  -o wide
```

Show recent workload events, including scheduling, PVC, image-pull, RBAC, and
admission failures:

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp |
  tail -150
```

If the StatefulSet exists, inspect its rollout and pod placement:

```sh
kubectl -n "$WORKLOAD_NAMESPACE" describe statefulset "$BROKER_CR-ss"

kubectl -n "$WORKLOAD_NAMESPACE" get pods \
  -l "ActiveMQArtemis=$BROKER_CR" \
  -o wide
```

## 5. Check operator authorization

These `kubectl auth can-i` requests perform authorization reviews only; they do
not create or change the named resources. The caller may need permission to
impersonate the operator ServiceAccount. Because an empty `WATCH_NAMESPACE`
in section 2 configures a cluster-wide informer, list/watch checks must use
`--all-namespaces`; a namespaced `can-i` result does not prove that the
operator can start its cluster-wide watches.

```sh
OPERATOR_ID="system:serviceaccount:$PLATFORM_NAMESPACE:$OPERATOR_SERVICE_ACCOUNT"

for resource in \
  activemqartemises.broker.amq.io \
  activemqartemisaddresses.broker.amq.io \
  activemqartemisscaledowns.broker.amq.io \
  activemqartemissecurities.broker.amq.io \
  statefulsets.apps \
  persistentvolumeclaims \
  services \
  secrets \
  configmaps \
  pods \
  ingresses.networking.k8s.io \
  serviceaccounts \
  poddisruptionbudgets.policy; do
  for verb in list watch; do
    kubectl auth can-i "$verb" "$resource" \
      --all-namespaces \
      --as "$OPERATOR_ID"
  done
done
```

For easier review, include the verb and resource in each result. The first six
checks validate cluster-wide informer startup; the remaining checks validate
representative writes in the workload namespace:

```sh
OPERATOR_ID="system:serviceaccount:$PLATFORM_NAMESPACE:$OPERATOR_SERVICE_ACCOUNT"

for check in \
  'get activemqartemises.broker.amq.io' \
  'list activemqartemises.broker.amq.io' \
  'watch activemqartemises.broker.amq.io' \
  'list configmaps' \
  'watch configmaps' \
  'list statefulsets.apps' \
  'watch statefulsets.apps'; do
  set -- $check
  result=$(kubectl auth can-i "$1" "$2" \
    --all-namespaces \
    --as "$OPERATOR_ID")
  printf '%-7s %-45s %-15s %s\n' "$1" "$2" cluster "$result"
done

for check in \
  'create statefulsets.apps' \
  'update statefulsets.apps' \
  'patch statefulsets.apps' \
  'create persistentvolumeclaims' \
  'create services' \
  'create secrets' \
  'create configmaps'; do
  set -- $check
  result=$(kubectl auth can-i "$1" "$2" \
    --namespace "$WORKLOAD_NAMESPACE" \
    --as "$OPERATOR_ID")
  printf '%-7s %-45s %-15s %s\n' "$1" "$2" "$WORKLOAD_NAMESPACE" "$result"
done
```

Inspect the binding that grants the cluster role. The subject namespace must
equal `$PLATFORM_NAMESPACE`, and `roleRef` must name
`activemq-artemis-operator-role`:

```sh
kubectl get clusterrolebinding activemq-artemis-operator-rolebinding -o json |
  yq '{"roleRef": .roleRef, "subjects": .subjects}'

kubectl get clusterrole activemq-artemis-operator-role -o json |
  yq '.rules[] |
    select(
      (.resources | contains(["activemqartemises"])) or
      (.resources | contains(["configmaps"])) or
      (.resources | contains(["statefulsets"]))
    )'
```

## 6. Inspect Gatekeeper and admission-policy evidence

List Gatekeeper constraint resource types and their current objects:

```sh
kubectl api-resources \
  --api-group=constraints.gatekeeper.sh \
  --verbs=list \
  -o name |
while IFS= read -r resource; do
  printf '\n### %s\n' "$resource"
  kubectl get "$resource" -A
done
```

List validating webhooks and identify policy engines that can reject generated
resources:

```sh
kubectl get validatingwebhookconfigurations.admissionregistration.k8s.io \
  -o name |
  grep -Ei 'gatekeeper|policy|admission'
```

Search the workload events for policy denials and missing required labels:

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp |
  grep -Ei 'gatekeeper|admission|denied|forbidden|required label|violation'
```

## 7. Collect a compact evidence bundle

This writes a local text file only. It does not modify cluster resources and
does not include the broker CR spec or Secret contents.

```sh
EVIDENCE_FILE="artemis-reconciliation-${APPLICATION}-$(date -u +%Y%m%dT%H%M%SZ).txt"

{
  printf '=== UTC time ===\n'
  date -u

  printf '\n=== Current context ===\n'
  kubectl config current-context

  printf '\n=== Argo Application status ===\n'
  kubectl -n "$ARGOCD_NAMESPACE" get application "$APPLICATION" -o json |
    yq '{"sync": .status.sync, "health": .status.health, "conditions": (.status.conditions // []), "source": .spec.source, "sources": (.spec.sources // [])}'

  printf '\n=== ApplicationSet status ===\n'
  kubectl -n "$ARGOCD_NAMESPACE" get applicationset "$APPLICATIONSET" -o json |
    yq '{"conditions": (.status.conditions // []), "templateSource": .spec.template.spec.source, "templateSources": (.spec.template.spec.sources // [])}'

  printf '\n=== Operator Deployment ===\n'
  kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o json |
    yq '{"generation": .metadata.generation, "replicas": .spec.replicas, "status": .status, "tolerations": (.spec.template.spec.tolerations // [])}'

  printf '\n=== Operator pods ===\n'
  kubectl -n "$PLATFORM_NAMESPACE" get pods \
    -l name=activemq-artemis-operator \
    -o wide

  printf '\n=== Broker CR status ===\n'
  kubectl -n "$WORKLOAD_NAMESPACE" get activemqartemis "$BROKER_CR" -o json |
    yq '{"name": .metadata.name, "namespace": .metadata.namespace, "generation": .metadata.generation, "status": (.status // {})}'

  printf '\n=== Generated resources ===\n'
  kubectl -n "$WORKLOAD_NAMESPACE" get \
    statefulsets,pods,persistentvolumeclaims,services,secrets,configmaps \
    -l "ActiveMQArtemis=$BROKER_CR" \
    -o wide

  printf '\n=== Workload events ===\n'
  kubectl -n "$WORKLOAD_NAMESPACE" get events \
    --sort-by=.metadata.creationTimestamp |
    tail -150

  printf '\n=== Filtered operator logs ===\n'
  kubectl -n "$PLATFORM_NAMESPACE" logs \
    -l name=activemq-artemis-operator \
    --all-containers=true \
    --prefix=true \
    --tail=500 |
    grep -Ei "$BROKER_CR|error|forbidden|denied|failed|resourceerror|watch|image"
} 2>&1 | tee "$EVIDENCE_FILE"

printf 'Evidence written to %s\n' "$EVIDENCE_FILE"
```

Review the file for credentials, tokens, message bodies, internal URLs, or
other sensitive values before attaching it outside the authorized environment.

## Interpretation

| Evidence | Meaning | Next repository or platform check |
|---|---|---|
| Operator has zero available replicas | The CR cannot be reconciled | Inspect operator events for scheduling, image-pull, or admission errors |
| `WATCH_NAMESPACE` excludes the workload namespace | The operator cannot observe the CR | Correct the environment-specific operator watch list |
| CR has no status or conditions | The operator has not processed the CR | Check operator availability, watched namespaces, logs, and CR list/watch RBAC |
| `Valid=False` | The operator rejected the desired broker configuration | Use the condition reason and message to correct the chart values |
| `Deployed=False` with `ResourceError` | A generated resource failed creation or update | Follow the condition message to RBAC, Gatekeeper, storage, or API validation |
| Operator log contains `forbidden` | Operator ServiceAccount authorization is incomplete | Compare `can-i` results with the vendored ClusterRole |
| Operator log or event contains `denied` | An admission policy rejected a generated object | Identify the constraint and missing or disallowed field |
| StatefulSet exists but pods do not | Reconciliation succeeded past resource creation | Inspect StatefulSet events, scheduling constraints, PVCs, and image pulls |
| `RepeatedResourceWarning` with nonempty `spec.sources` | More than one Argo source may render the same identity | Remove source drift and restore the ApplicationSet-owned single `spec.source` |
| `RepeatedResourceWarning` with one `spec.source` and current Helm output contains one copy of the named resource | The condition may belong to an older Git revision or stale Argo manifest cache | Compare `.status.sync.revision` with the intended commit, then request a hard refresh through the authorized Argo CD workflow |
| Deployment sync fails with `spec.selector ... field is immutable` | The desired chart selector differs from the eight-label selector stored by the existing enterprise-labelled Deployment | Render the compatibility selector from the same release and environment values, confirm it is identical to the live map, and sync that revision without forcing or replacing the Deployment |
| Cluster-scoped log `forbidden` while `WATCH_NAMESPACE` is empty | The operator's cluster-wide informers cannot start | Restore the rendered ClusterRole and ClusterRoleBinding, then confirm every cluster-scope `can-i` result is `yes` |
