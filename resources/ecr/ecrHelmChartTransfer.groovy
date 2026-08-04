@Library('PLACEHOLDER_SHARED_LIB') _

import PLACEHOLDER_ECR_IMPORT

def fromRepo = params.FROM_REPO ?: ''
def fromChart = params.FROM_CHART ?: ''
def fromChartVersion = params.FROM_CHART_VERSION ?: ''
def toRepo = params.TO_REPO ?: 'nonprod'
def toChartRepository = params.TO_CHART_REPOSITORY ?: ''
def awsRegion = 'us-east-1'

if (!fromRepo || !fromChart || !fromChartVersion || !toChartRepository) {
    error('FROM_REPO, FROM_CHART, FROM_CHART_VERSION, and TO_CHART_REPOSITORY are required')
}

def agentLabels = [
    nonprod: 'PLACEHOLDER_NONPROD_AGENT_LABEL',
    prod: 'PLACEHOLDER_PROD_AGENT_LABEL'
]
def agentLabel = agentLabels[toRepo]
def helmImages = [
    nonprod: 'PLACEHOLDER_NONPROD_HELM_IMAGE@sha256:PLACEHOLDER_HELM_IMAGE_DIGEST',
    prod: 'PLACEHOLDER_PROD_HELM_IMAGE@sha256:PLACEHOLDER_HELM_IMAGE_DIGEST'
]
def helmImage = helmImages[toRepo]
if (!agentLabel || !helmImage) {
    error("Unsupported TO_REPO value: ${toRepo}")
}

node(agentLabel) {
    stage('Checkout') {
        checkout scm
    }

    stage('Transfer Helm Chart') {
        // Keep destination account selection consistent with ECR-TransferImage.
        ECR.login(this, toRepo)

        def repositoryUri
        withEnv([
            "TO_CHART_REPOSITORY=${toChartRepository}",
            "AWS_REGION=${awsRegion}"
        ]) {
            repositoryUri = sh(
                label: 'Resolve destination ECR repository',
                returnStdout: true,
                script: '''aws ecr describe-repositories \
                    --region "$AWS_REGION" \
                    --repository-names "$TO_CHART_REPOSITORY" \
                    --query 'repositories[0].repositoryUri' \
                    --output text'''
            ).trim()
        }
        if (!repositoryUri || repositoryUri == 'None' || !repositoryUri.contains('/')) {
            error("AWS did not return a valid ECR repository URI for ${toChartRepository}")
        }
        def dockerConfig = "${env.HOME}/.docker/config.json"
        def containerUid = sh(returnStdout: true, script: 'id -u').trim()
        def containerGid = sh(returnStdout: true, script: 'id -g').trim()
        sh(label: 'Check Docker registry credentials', script: "test -r '${dockerConfig}'")

        docker.image(helmImage).inside(
            "--entrypoint='' --user ${containerUid}:${containerGid} " +
            "-v ${dockerConfig}:/tmp/docker-config.json:ro"
        ) {
            withEnv([
                "FROM_REPO=${fromRepo}",
                "FROM_CHART=${fromChart}",
                "FROM_CHART_VERSION=${fromChartVersion}",
                "TO_CHART_REPOSITORY=${toChartRepository}",
                "ECR_REPOSITORY_URI=${repositoryUri}",
                'HELM_REGISTRY_CONFIG=/tmp/docker-config.json'
            ]) {
                sh(
                    label: 'Pull and push Helm chart',
                    script: 'sh resources/ecr/transfer-helm-chart.sh'
                )
            }
        }
    }
}
