# Hawtio redirect URLs for every workload cell

`argocd/topology/{test,nonprod,prod}.yaml` owns each cell's `managementHost`.
The ApplicationSet uses that same host for ingress and sets the callback to
`https://<managementHost>/console`. Change the hostname in topology, not in a
cell values file: the ApplicationSet parameter overrides Helm values.

Generate the complete inventory from the repository root (Python 3 and the
repository's Mike Farah yq v4 are required):

```bash
python3 gitops/scripts/hawtio-redirects.py
```

The JSON groups cells and `redirectUris` by issuer URL and client ID. Test and
nonprod currently share the preprod client; prod has a separate client. Disabled
cells are included so their callbacks can be registered before activation.
This is a review report, not an importable realm configuration.

Each hostname is `<workloadNamespace>.<cluster-domain-placeholder>`. The entire
domain after the cell name is one replacement token, including the `k8s` prefix
and every remaining domain label. Replace these tokens on the work computer:

| Topology | Replace this complete token with its approved cluster domain |
| --- | --- |
| test | `placeholder-test-domain.example.invalid` |
| nonprod | `placeholder-nonprod-domain.example.invalid` |
| prod | `placeholder-prod-domain.example.invalid` |

Use the exact `workloadNamespace` as the first DNS label, including its existing
`artemis-` prefix. For example, the stored test callback is
`https://artemis-int-sky.placeholder-test-domain.example.invalid/console`.
The replacement domain starts with `k8s.<eks-cluster>.` and includes the full
remaining approved domain. Test uses its nonproduction cluster domain; test and
nonprod have separate tokens because they can target different EKS clusters.
Keep the real domains out of this offline copy.

The callback path is `/console`, with no trailing slash or wildcard. The
ApplicationSet adds the HTTPS scheme and path; `managementHost` contains only
the hostname. Arrange matching ingress DNS and TLS coverage, then generate
each client's exact callback list:

```bash
python3 gitops/scripts/hawtio-redirects.py \
  --environment test --environment nonprod --format urls --require-real-hosts
python3 gitops/scripts/hawtio-redirects.py \
  --environment prod --format urls --require-real-hosts
```

The real-host check rejects placeholder callback hosts. Confirm the environment
issuer URLs and client IDs also identify the intended real Keycloak clients.
Generation makes no network requests and does not change Keycloak.

Merge these exact URLs with existing legitimate callbacks, including legacy
Hawtio instances, in the shared client's Valid Redirect URIs. Preserve unrelated
client settings. Once every legitimate callback is accounted for, remove the
standalone `*`; adding explicit URLs while keeping it does not restrict redirects.
Use the Keycloak toolkit's reviewed configuration workflow for the external
application step; do not import this report or replace a shared client's list
with only the Artemis URLs. Verify browser login for each activated cell on the
work computer after applying.

Validate generation and its agreement with the ApplicationSet locally:

```bash
python3 gitops/tests/topology/test-hawtio-redirects.py
```
