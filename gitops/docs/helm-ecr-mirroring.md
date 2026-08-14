# Helm chart mirroring to ECR

Status: deferred while the POC uses the public upstream chart source
Applies to: Gov nonproduction and production ECR Terraform

## Repository contract

Amazon ECR uses the same repository resource for container images and Helm OCI
artifacts. Create one immutable ECR repository per chart. For Artemis, the
current third-party chart inventory is:

| ECR repository | Upstream chart | Approved version |
| --- | --- | --- |
| `artemis/helm/arkmq-org-broker-operator` | `oci://quay.io/arkmq-org/helm-charts/arkmq-org-broker-operator` | `2.2.0` |

The ECR repository name includes the chart name. Push to its parent namespace,
`oci://<registry>/artemis/helm`; Helm appends the chart name and version.

## Terraform extension

Add the chart repositories as a separate input instead of mixing them into the
mutable image-repository lists shown in the existing ECR configuration.

`variables.tf`:

```hcl
variable "helm_repo_names" {
  description = "ECR repositories containing promoted Helm OCI charts"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for name in var.helm_repo_names : startswith(name, "artemis/helm/")
    ])
    error_message = "Helm repositories must use the artemis/helm/<chart-name> namespace."
  }
}
```

Add to the existing `locals` block in `main.tf`:

```hcl
helm_repo_map = {
  for repo in var.helm_repo_names : repo => repo
}
```

Add the repositories in `main.tf`:

```hcl
resource "aws_ecr_repository" "helm_repo" {
  for_each = local.helm_repo_map

  name                 = each.key
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.PLACEHOLDER_PROJECT-ecr.arn
  }

  lifecycle {
    prevent_destroy = true
  }
}
```

Add an output if the platform pipeline consumes repository URLs:

```hcl
output "helm_repository_urls" {
  description = "Private ECR repositories for promoted Helm OCI charts"
  value = {
    for name, repository in aws_ecr_repository.helm_repo :
    name => repository.repository_url
  }
}
```

The role used by the approved import pipeline and the Argo CD credential
refresh integration needs ECR authorization plus read access to the chart
repositories. Adapt this policy document to the existing IAM-role module:

```hcl
data "aws_iam_policy_document" "helm_ecr_read" {
  statement {
    sid       = "GetEcrAuthorizationToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "ReadApprovedHelmCharts"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [
      for repository in aws_ecr_repository.helm_repo : repository.arn
    ]
  }
}
```

The import role additionally needs the narrowly scoped ECR upload actions.
Keep import/write permissions separate from Argo CD's read-only access.

Add to both environment `terraform.tfvars` files:

```hcl
helm_repo_names = [
  "artemis/helm/arkmq-org-broker-operator",
]
```

Do not attach the existing "keep last 100 images" lifecycle policy to these
repositories. A chart version still pinned by Git must not disappear because
it became the 101st artifact. Retire tagged chart versions through an explicit,
approved process. ECR image scanning also does not replace chart rendering,
RBAC review, policy checks, signature verification, or provenance validation.

## Controlled import

Run this in the approved connected import pipeline, not in Argo CD:

```sh
helm pull \
  oci://quay.io/arkmq-org/helm-charts/arkmq-org-broker-operator \
  --version 2.2.0

aws ecr get-login-password --region "$AWS_REGION" |
  helm registry login \
    --username AWS \
    --password-stdin \
    "$ECR_REGISTRY"

helm push \
  arkmq-org-broker-operator-2.2.0.tgz \
  "oci://$ECR_REGISTRY/artemis/helm"
```

Capture the digest printed by `helm push` and verify ECR reports the Helm
artifact media type:

```sh
aws ecr describe-images \
  --region "$AWS_REGION" \
  --repository-name artemis/helm/arkmq-org-broker-operator \
  --image-ids imageTag=2.2.0 \
  --query 'imageDetails[0].{digest:imageDigest,mediaType:artifactMediaType,tags:imageTags}'
```

The repository includes the
[`ECR-TransferHelmChart` seed definition](../../jobs/ecr/ecrTransferHelmChart.groovy),
its [Scripted Pipeline](../../resources/ecr/ecrHelmChartTransfer.groovy), and the
[`transfer-helm-chart.sh`](../../resources/ecr/transfer-helm-chart.sh) helper.
The pipeline uses the same `PLACEHOLDER_SHARED_LIB` ECR login and `TO_REPO`
environment selector as the container-image transfer job, with these build
parameters:

| Parameter | Example | Meaning |
| --- | --- | --- |
| `FROM_REPO` | `oci://quay.io/arkmq-org/helm-charts` | Source OCI namespace |
| `FROM_CHART` | `arkmq-org-broker-operator` | Chart name |
| `FROM_CHART_VERSION` | `2.2.0` | Exact version to transfer |
| `TO_REPO` | `nonprod` | Destination environment resolved by the shared library |
| `TO_CHART_REPOSITORY` | `artemis/helm/arkmq-org-broker-operator` | Exact destination ECR repository |

The shared library selects the destination AWS account, provides AWS CLI
access, and authenticates Docker. Chart pull and push run in a pinned Helm-only
image mirrored to each destination ECR. Helm reads the host Docker login through
a read-only registry-config mount. Before transfer, the pipeline verifies that
the destination repository is immutable. After transfer, it verifies the Helm
artifact media type and destination digest, then archives a fingerprinted
`helm-promotion-record.json`. The destination region is fixed to `us-east-1`
rather than exposed as a parameter.

Use `alpine/helm:<approved-version>` as the Helm runtime image, then mirror it
into each environment's immutable-tag ECR repository and replace the
pipeline's image placeholder. The image includes the POSIX shell and Alpine
utilities required by the transfer script.

The promotion record must include the upstream location, chart digest, image
tag, version, license, SBOM, vulnerability scan, signature/provenance result,
rendered-manifest policy result, approval, and import date. Promote the same
tagged build to production; do not rebuild or repackage between environments.

## Artemis and Argo CD wiring

Runtime image locations are derived from two ECR base placeholders:

| Placeholder | Example value; no `oci://` prefix or artifact name |
| --- | --- |
| `PLACEHOLDER_NONPROD_ECR_REPOSITORY` | `123456789012.dkr.ecr.us-east-1.amazonaws.com/artemis` |
| `PLACEHOLDER_PROD_ECR_REPOSITORY` | `210987654321.dkr.ecr.us-east-1.amazonaws.com/artemis` |

The operator Applications use the Artemis Git repository and point to the
matching Kustomize overlay. Kustomize inflates the pinned, unmodified public
OCI chart and patches only the final Kubernetes objects. The environment image
patch selects the approved operator, init, and broker tags from the Platform
Release. Each tag must already exist in the target private ECR repository.

The mirrored upstream Helm artifact remains approved provenance and an offline
validation input. The current Argo deployment source is the public chart in the
Kustomize base, so repo-server does not need ECR chart credentials. Moving that
source to ECR is a separate reviewed change because the Helm subprocess invoked
by Kustomize must receive working registry authentication.

Register each ECR chart namespace as a Helm repository with OCI enabled, but
provide authentication once per registry through an Argo CD repository
credential template. Argo CD applies that template to every repository URL
with the registry hostname as its prefix, including charts owned by other
applications. The operator Application's Argo source remains Git, so its
`AppProject.sourceRepos` entry remains the Git repository. Before changing the
Kustomize `helmCharts.repo` to ECR, verify on the approved Argo CD version that
the Kustomize-invoked Helm process receives the refreshed registry credentials.

Do not store the output of `aws ecr get-login-password` as a long-lived
Terraform secret: ECR authorization tokens expire. Connect the repo-server to
the Gov platform's approved ECR credential-refresh mechanism and grant the
refresh identity read access only to approved Helm repositories. The ECR token
inherits the IAM principal's permissions, so a shared credential must not use
a broad write-capable role.

The repository provides a refresh helper that obtains a new token without
printing it and applies a registry-wide Argo CD Helm/OCI `repo-creds` Secret.
Invoke it from the platform-owned scheduler at least once every ten hours and
once during bootstrap:

```sh
export ARGOCD_NAMESPACE=argocd
export AWS_REGION=us-east-1
export ECR_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
export ARGOCD_REPO_CREDS_SECRET=ecr-helm-oci-creds
export KUBECTL_CONTEXT=PLACEHOLDER_TEST_KUBECTL_CONTEXT
gitops/scripts/refresh-argocd-ecr-credential.sh
```

The caller needs `ecr:GetAuthorizationToken`; its Kubernetes identity needs
only `get`, `create`, `patch`, and `update` access to the
`ecr-helm-oci-creds` Secret in the Argo CD namespace. The credential-template
URL is the ECR registry hostname without `https://`, `oci://`, a namespace, or
a chart name. Repository definitions and the Kustomize chart reference must not
contain credentials of their own, because Argo CD only applies a matching
credential template when repository-specific credentials are absent.

Run the helper once per ECR registry used by an Argo CD instance. If an
instance must access multiple accounts or regions, give each invocation a
different `ARGOCD_REPO_CREDS_SECRET` value. Do not place any generated Secret
or password in Git.

When migrating an existing installation, apply and verify the shared
`repo-creds` Secret first. Then remove the legacy `artemis-ecr-helm` repository
Secret, or remove its `username` and `password` fields if the platform retains
it as a repository definition. A repository-specific credential takes
precedence over a matching credential template, so leaving the old ECR token
in place would cause Artemis to fail when that token expires even though the
shared template is current.

For secure CI, download the promoted unmodified chart and pass it to the
repository renderer. The recorded checksum is enforced before rendering:

```sh
export ARKMQ_UPSTREAM_CHART=/approved/path/arkmq-org-broker-operator-2.2.0.tgz
make validate-operator-kustomize
make validate-operator-schema
```
