# Helm chart mirroring to ECR

Status: platform handoff  
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
a read-only registry-config mount. ECR repository immutability rejects an
existing chart version. The destination region is fixed to `us-east-1` rather
than exposed as a parameter.

Use `alpine/helm:<approved-version>` as the Helm runtime image, then mirror it
into each environment's ECR and replace the pipeline's image and digest
placeholders. The image includes the POSIX shell and Alpine utilities required
by the transfer script. Pin and promote the reviewed digest, not a floating
tag.

The promotion record must include the upstream location, upstream and ECR
digests, version, license, signature/provenance result, rendered-manifest
policy result, approval, and import date. Promote the same bytes to production;
do not rebuild or repackage between environments.

## Artemis and Argo CD wiring

The operator Applications in `gitops/argocd/bootstrap` expect these placeholder
values:

| Placeholder | Example value; no `oci://` prefix |
| --- | --- |
| `PLACEHOLDER_NONPROD_HELM_OCI_REPOSITORY` | `123456789012.dkr.ecr.us-east-1.amazonaws.com/artemis/helm` |
| `PLACEHOLDER_PROD_HELM_OCI_REPOSITORY` | `210987654321.dkr.ecr.us-east-1.amazonaws.com/artemis/helm` |

Argo CD appends the configured chart name
`arkmq-org-broker-operator`. The `messaging-platform` AppProject must allow the
exact Git URL and the matching ECR Helm namespace in `sourceRepos`.

Register the ECR namespace as a Helm repository with OCI enabled. Do not store
the output of `aws ecr get-login-password` as a long-lived Terraform secret:
ECR authorization tokens expire. Connect the repo-server to the Gov platform's
approved ECR credential-refresh mechanism and grant only the ECR read actions
needed to retrieve approved artifacts.

For secure CI, override the public development default used by contract tests:

```sh
export ARKMQ_OPERATOR_CHART="oci://$ECR_REGISTRY/artemis/helm/arkmq-org-broker-operator"
make validate-operator-schema
```
