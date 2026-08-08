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

OPERATOR_DEPLOYMENT=activemq-artemis-controller-manager-v2
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

## Step-by-step triage

Run these steps in order. Stop at the first failed boundary and use its noted
follow-up; do not skip directly to pod scheduling when the operator has not
created a StatefulSet. In this deployment, Argo CD directly owns the Services,
ServiceAccount, monitoring resources, NetworkPolicies, and
`ActiveMQArtemis` CR. The ArkMQ operator separately owns the broker StatefulSet
and pods. Therefore, green Argo resources do not by themselves prove broker
reconciliation.

### Step 1: Run the repository verifier

Run this from the root of the authorized work-computer checkout. It performs
only read operations and checks the ApplicationSet, operator availability,
watch scope, RBAC, child Application, broker CR conditions, and expected
StatefulSet in one pass.

```sh
./gitops/scripts/verify-argocd-applicationset.sh \
  --context "$(kubectl config current-context)" \
  --argocd-namespace "$ARGOCD_NAMESPACE" \
  --environment test
```

Interpret the first reported error as the failed boundary:

- Operator Deployment missing or zero available replicas: continue with steps
  2 and 3.
- Nonempty `WATCH_NAMESPACE` or an RBAC denial: continue with step 4.
- Broker CR has no status conditions: continue with steps 4, 5, and 7.
- `Valid=False` or `Deployed=False`: preserve the reason and message, then use
  steps 7 and 12.
- StatefulSet exists but has zero ready replicas: continue with steps 8-11.

If the verifier is not yet present in the work-computer revision, continue
with the direct commands below.

### Step 2: Confirm the Argo Applications and revisions

Check the workload Application and the operator Application together. The
operator Application must be current before a synced broker CR can produce a
StatefulSet.

```sh
for app in "$APPLICATION" "$OPERATOR_APPLICATION"; do
  kubectl -n "$ARGOCD_NAMESPACE" get application "$app" -o json |
    yq '{
      "application": .metadata.name,
      "configuredRevision": (.spec.source.targetRevision // ""),
      "reconciledRevision": (.status.sync.revision // ""),
      "sync": (.status.sync.status // ""),
      "health": (.status.health.status // ""),
      "conditions": (.status.conditions // []),
      "operationPhase": (.status.operationState.phase // ""),
      "operationMessage": (.status.operationState.message // "")
    }'
done
```

Expected result: both Applications are `Synced`, the operator is `Healthy`,
and neither has an error condition. If the operator operation mentions an
immutable Deployment selector, use the focused immutable-selector section
below. If only the configured revision is current, the latest manifests have
not completed reconciliation.

### Step 3: Confirm that the operator can run

The expected controller is a Deployment in the platform namespace. Its absence
or zero available replicas fully explains a broker CR with no StatefulSet.

```sh
kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o json |
  yq '{
    "name": .metadata.name,
    "generation": .metadata.generation,
    "observedGeneration": (.status.observedGeneration // 0),
    "desired": (.spec.replicas // 0),
    "updated": (.status.updatedReplicas // 0),
    "ready": (.status.readyReplicas // 0),
    "available": (.status.availableReplicas // 0),
    "conditions": (.status.conditions // [])
  }'

kubectl -n "$PLATFORM_NAMESPACE" get pods \
  -l name=activemq-artemis-operator \
  -o wide
```

If the Deployment is missing, return to the operator Application in step 2.
If pods are pending or restarting, capture their exact waiting and termination
messages:

```sh
kubectl -n "$PLATFORM_NAMESPACE" get pods \
  -l name=activemq-artemis-operator \
  -o json |
  yq -r '.items[] |
    .metadata.name as $pod |
    .status.containerStatuses[]? |
    [
      $pod,
      .name,
      (.state.waiting.reason // .state.terminated.reason // "running"),
      (.state.waiting.message // .state.terminated.message // "")
    ] | @tsv'

kubectl -n "$PLATFORM_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp |
  tail -100
```

An `ErrImagePull` or `ImagePullBackOff` on the manager is an operator-image
problem, not a broker-image problem. Record the desired manager image:

```sh
kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o json |
  yq -r '.spec.template.spec.containers[] |
    select(.name == "manager") |
    .image'
```

### Step 4: Confirm operator watch scope and effective RBAC

An empty `WATCH_NAMESPACE` means cluster-wide watch scope for this chart. A
nonempty value that does not include `$WORKLOAD_NAMESPACE` prevents the
operator from seeing the broker CR.

```sh
kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o json |
  yq -r '.spec.template.spec.containers[] |
    select(.name == "manager") |
    .env[] |
    select(.name == "WATCH_NAMESPACE") |
    "WATCH_NAMESPACE=" + (.value // "")'

kubectl get clusterrolebinding activemq-artemis-operator-rolebinding -o json |
  yq '{"roleRef": .roleRef, "subjects": .subjects}'
```

Test the operator ServiceAccount's effective permissions. These commands
create `SelfSubjectAccessReview`/`SubjectAccessReview` requests only; they do
not create broker resources.

```sh
OPERATOR_ID="system:serviceaccount:$PLATFORM_NAMESPACE:$OPERATOR_SERVICE_ACCOUNT"

for check in \
  'list activemqartemises.broker.amq.io' \
  'watch activemqartemises.broker.amq.io' \
  'list configmaps' \
  'watch configmaps' \
  'list statefulsets.apps' \
  'watch statefulsets.apps'; do
  set -- $check
  printf '%-7s %-45s ' "$1" "$2"
  kubectl auth can-i "$1" "$2" \
    --all-namespaces \
    --as "$OPERATOR_ID"
done

for check in \
  'create statefulsets.apps' \
  'update statefulsets.apps' \
  'create persistentvolumeclaims' \
  'create services' \
  'create secrets' \
  'create configmaps'; do
  set -- $check
  printf '%-7s %-45s ' "$1" "$2"
  kubectl auth can-i "$1" "$2" \
    --namespace "$WORKLOAD_NAMESPACE" \
    --as "$OPERATOR_ID"
done
```

Expected result: every answer is `yes`. If impersonation itself is forbidden,
preserve that response and ask an authorized cluster administrator to run this
step. A cluster-wide list/watch `no` prevents informer startup; a namespaced
create/update `no` prevents workload generation.

### Step 5: Read the broker CR's reconciliation result

This is the decisive check when Argo shows the CR as synced but no StatefulSet
appears.

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get activemqartemis "$BROKER_CR" -o json |
  yq '{
    "name": .metadata.name,
    "namespace": .metadata.namespace,
    "generation": .metadata.generation,
    "finalizers": (.metadata.finalizers // []),
    "conditions": (.status.conditions // []),
    "podStatus": (.status.podStatus // {})
  }'

kubectl -n "$WORKLOAD_NAMESPACE" get activemqartemis "$BROKER_CR" \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.observedGeneration}{"\t"}{.message}{"\n"}{end}'
```

Interpretation:

- No conditions: the operator has not observed or processed the CR. Return to
  steps 3, 4, and 7.
- `Valid=False`: the CR spec was rejected. The condition message should name
  the invalid field or unsupported value.
- `Deployed=False` with `ResourceError`: a generated object failed. Continue
  with steps 7 and 12 for the exact RBAC or admission denial.
- Conditions refer to an older `observedGeneration`: the operator has not
  reconciled the current CR generation.
- `Valid=True` and `Deployed=True`: workload creation progressed; continue
  with step 6.

### Step 6: Check the expected operator-generated StatefulSet

The broker is intentionally managed by a StatefulSet, not a Deployment. Its
expected name is the broker CR name plus `-ss`.

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get statefulset "$BROKER_CR-ss" -o json |
  yq '{
    "name": .metadata.name,
    "generation": .metadata.generation,
    "observedGeneration": (.status.observedGeneration // 0),
    "desired": (.spec.replicas // 0),
    "current": (.status.currentReplicas // 0),
    "ready": (.status.readyReplicas // 0),
    "updated": (.status.updatedReplicas // 0),
    "conditions": (.status.conditions // [])
  }'
```

If this returns `NotFound`, do not debug pod scheduling, PVC binding, or broker
image pulls yet—no pod template exists. Continue with step 7. If it exists,
continue with step 8.

### Step 7: Explain a missing StatefulSet from operator logs and events

Filter by the exact CR name first, while retaining common authorization,
admission, image-resolution, and reconciliation errors.

```sh
kubectl -n "$PLATFORM_NAMESPACE" logs \
  -l name=activemq-artemis-operator \
  --all-containers=true \
  --prefix=true \
  --tail=1000 |
  grep -Ei "$BROKER_CR|error|forbidden|denied|failed|resourceerror|watch|image"

kubectl -n "$WORKLOAD_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp |
  tail -150

kubectl -n "$PLATFORM_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp |
  tail -150
```

Preserve the first complete error message. `forbidden` points to step 4;
`denied` or a constraint name points to step 12; image-resolution errors name
the required related-image variable or reference; validation errors point back
to the CR condition in step 5.

### Step 8: Inspect broker pods and PVCs after the StatefulSet exists

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get \
  statefulsets,pods,persistentvolumeclaims \
  -l "ActiveMQArtemis=$BROKER_CR" \
  -o wide

kubectl -n "$WORKLOAD_NAMESPACE" get pods \
  -l "ActiveMQArtemis=$BROKER_CR" \
  -o json |
  yq -r '.items[] |
    [
      .metadata.name,
      (.status.phase // ""),
      (.spec.nodeName // "<unassigned>"),
      ([.status.conditions[]? |
        select(.status == "False") |
        .type + ":" + .reason] | join(","))
    ] | @tsv'
```

If no pod objects exist even though the StatefulSet desires two replicas,
inspect the StatefulSet and namespace events:

```sh
kubectl -n "$WORKLOAD_NAMESPACE" describe statefulset "$BROKER_CR-ss"
kubectl -n "$WORKLOAD_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp |
  tail -150
```

### Step 9: Diagnose pending or restarting broker pods

Describe each broker pod to capture scheduler, mount, admission, init-container,
probe, and image-pull events without reading Secret values.

```sh
for pod in $(kubectl -n "$WORKLOAD_NAMESPACE" get pods \
  -l "ActiveMQArtemis=$BROKER_CR" \
  -o name); do
  kubectl -n "$WORKLOAD_NAMESPACE" describe "$pod"
done
```

Use the event reason to select the next step:

- `FailedScheduling`: inspect node selectors, taints/tolerations, topology
  constraints, and available zones.
- `FailedAttachVolume`, `FailedMount`, or PVC `Pending`: use step 10.
- `ErrImagePull` or `ImagePullBackOff`: use step 11.
- `CreateContainerConfigError`: inspect the named missing ConfigMap or Secret;
  do not print Secret contents.
- Repeated startup, readiness, or liveness failures: preserve the probe event
  and broker container logs.

For scheduling evidence, print only the relevant placement fields and node
taints:

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get statefulset "$BROKER_CR-ss" -o json |
  yq '{
    "nodeSelector": (.spec.template.spec.nodeSelector // {}),
    "tolerations": (.spec.template.spec.tolerations // []),
    "affinity": (.spec.template.spec.affinity // {}),
    "topologySpreadConstraints": (.spec.template.spec.topologySpreadConstraints // [])
  }'

kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints' \
  --no-headers
```

### Step 10: Diagnose PVC and StorageClass failures

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get persistentvolumeclaims \
  -l "ActiveMQArtemis=$BROKER_CR" \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName,VOLUME:.spec.volumeName,REQUEST:.spec.resources.requests.storage'

kubectl -n "$WORKLOAD_NAMESPACE" describe persistentvolumeclaims \
  -l "ActiveMQArtemis=$BROKER_CR"

kubectl get storageclass
```

Expected result: one bound `ReadWriteOnce` claim per broker pod. A missing
StorageClass, provisioner error, quota denial, or zone/topology conflict will
appear in the PVC events.

### Step 11: Diagnose broker image-pull failures

Print desired image references and waiting messages without exposing container
environment values:

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get pods \
  -l "ActiveMQArtemis=$BROKER_CR" \
  -o json |
  yq -r '.items[] |
    .metadata.name as $pod |
    ((.spec.initContainers // []) + (.spec.containers // []))[] |
    [$pod, .name, .image] | @tsv'

kubectl -n "$WORKLOAD_NAMESPACE" get pods \
  -l "ActiveMQArtemis=$BROKER_CR" \
  -o json |
  yq -r '.items[] |
    .metadata.name as $pod |
    ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[] |
    select(.state.waiting != null) |
    [$pod, .name, .state.waiting.reason, (.state.waiting.message // "")] |
    @tsv'
```

Also confirm the operator Deployment contains private-registry related-image
references for the broker version selected by the CR:

```sh
kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o json |
  yq -r '.spec.template.spec.containers[] |
    select(.name == "manager") |
    .env[] |
    select(.name | startswith("RELATED_IMAGE_ActiveMQ_Artemis_Broker_")) |
    [.name, .value] | @tsv' |
  grep '2530'
```

For broker version `2.53.0`, both the init and Kubernetes image variables ending
in `2530` must exist. A private repository combined with an upstream-only
digest can yield `not found`; an ECR authorization failure instead reports a
token or pull-authorization error.

### Step 12: Diagnose Gatekeeper or another admission denial

Use this only when the CR condition, operator log, or event contains `denied`,
`admission`, `constraint`, or a required-label message.

```sh
kubectl -n "$WORKLOAD_NAMESPACE" get events \
  --sort-by=.metadata.creationTimestamp |
  grep -Ei 'gatekeeper|admission|denied|forbidden|required label|violation'

kubectl get validatingwebhookconfigurations.admissionregistration.k8s.io \
  -o name |
  grep -Ei 'gatekeeper|policy|admission'

kubectl api-resources \
  --api-group=constraints.gatekeeper.sh \
  --verbs=list \
  -o name
```

If the event names a constraint kind, retrieve only that constraint's metadata,
match scope, and enforcement fields first; do not make speculative policy
changes. The generated StatefulSet must carry the enterprise labels encoded by
the CR's unscoped `resourceTemplates` entry.

### Step 13: Record the stopping point

Summarize the first failed boundary and attach only the relevant evidence:

```text
Argo workload Application: Synced/Healthy or failure
Argo operator Application: Synced/Healthy or failure
Operator Deployment: desired/available and manager image state
WATCH_NAMESPACE and RBAC: expected values and first denial
Broker CR: generation plus complete conditions
StatefulSet: NotFound or desired/current/ready
Pods: phase plus first warning event
PVCs: phase plus first warning event
Admission/image evidence: exact first error
```

The later sections provide deeper commands for a specific failure class and a
compact evidence bundle. They are reference material after this ordered path,
not prerequisites to run before step 1.

## Operator Deployment immutable-selector sync failure

Use this focused sequence when Argo CD reports
`spec.selector ... field is immutable`. Earlier chart revisions rendered
different selectors for the same `activemq-artemis-controller-manager`
identity, so selecting another label map cannot repair every installation. The
current chart instead renders `activemq-artemis-controller-manager-v2` with a
stable two-label selector. Argo creates that replacement and `PruneLast=true`
keeps the old controller available until the replacement is healthy, after
which automated pruning removes it. This sequence confirms the Application
identity, desired revision, old-resource pruning state, and replacement
Deployment.

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
equal the commit containing the replacement Deployment before later cluster
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
      ][0] // ""),
      "clusterScoped": ([
        .spec.source.helm.parameters[]? |
        select(.name == "arkmq-org-broker-operator.clusterScoped") |
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
          .name == "activemq-artemis-controller-manager-v2" or
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
      .name == "activemq-artemis-controller-manager-v2" or
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

After the new revision is reconciled, the `-v2` row must be present and the old
Deployment may appear temporarily with `requiresPruning=true`. If only the old
Deployment appears, Argo has not rendered the replacement revision. If the old
Deployment remains after `-v2` becomes Healthy, inspect whether automated prune
is still enabled on the operator Application.

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

Preserve every `NotFound` response. Do not delete or recreate either Deployment
manually while Argo owns the Application; the chart and automated pruning own
the replacement lifecycle.

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

### 5. Verify the replacement identity and stable selector

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
    .metadata.name == "activemq-artemis-controller-manager-v2"
  ) | {
    "name": .metadata.name,
    "labels": .metadata.labels,
    "selector": .spec.selector.matchLabels,
    "podLabels": .spec.template.metadata.labels,
    "serviceAccountName": .spec.template.spec.serviceAccountName
  }'
```

The rendered and live replacement selectors must contain exactly
`control-plane=controller-manager` and `name=activemq-artemis-operator`. The pod
labels must additionally contain the Helm and required enterprise labels. If
the `-v2` Deployment is absent, first verify the Application revision and
rendered output; do not delete the old Deployment manually.

## Focused RBAC deep dive

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

## Deep dive: check the effective Argo CD Application

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

## Deep dive: confirm that the ArkMQ operator is running

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

For `ErrImagePull`, print the exact desired manager reference and its waiting
message. A private ECR reference ending in `@sha256:... not found` means the
specified digest is absent from that repository; it is distinct from an ECR
authorization failure.

```sh
kubectl -n "$PLATFORM_NAMESPACE" get deployment "$OPERATOR_DEPLOYMENT" -o json |
  yq -r '.spec.template.spec.containers[] |
    select(.name == "manager") |
    "desiredImage=" + .image'

kubectl -n "$PLATFORM_NAMESPACE" get pods \
  -l name=activemq-artemis-operator \
  -o json |
  yq -r '.items[] |
    .metadata.name as $pod |
    .status.containerStatuses[]? |
    select(.name == "manager") |
    [$pod, (.state.waiting.reason // ""), (.state.waiting.message // "")] |
    @tsv'
```

From the authorized work computer, this read-only ECR query confirms that the
mirrored tag exists and records the target registry's digest. Set the region
and repository name to the values from the desired image reference.

```sh
AWS_REGION=us-east-1
OPERATOR_ECR_REPOSITORY=artemis/arkmq-operator

aws ecr describe-images \
  --region "$AWS_REGION" \
  --repository-name "$OPERATOR_ECR_REPOSITORY" \
  --image-ids imageTag=2.2.0 \
  --query 'imageDetails[].{digest:imageDigest,tags:imageTags,pushedAt:imagePushedAt}'
```

## Deep dive: read the broker CR reconciliation status

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

## Deep dive: check for operator-generated resources

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

## Deep dive: check operator authorization

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

## Deep dive: inspect Gatekeeper and admission-policy evidence

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

## Collect a compact evidence bundle

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
| Deployment sync fails with `spec.selector ... field is immutable` | Argo is still reconciling an older revision against the original Deployment identity | Confirm the intended revision renders `activemq-artemis-controller-manager-v2`, sync it through the authorized Argo workflow, and let automated prune retire the original Deployment |
| Cluster-scoped log `forbidden` while `WATCH_NAMESPACE` is empty | The operator's cluster-wide informers cannot start | Restore the rendered ClusterRole and ClusterRoleBinding, then confirm every cluster-scope `can-i` result is `yes` |
