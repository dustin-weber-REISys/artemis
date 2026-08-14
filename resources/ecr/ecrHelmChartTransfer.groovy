@Library('PLACEHOLDER_SHARED_LIB') _

import PLACEHOLDER_ECR_IMPORT
import groovy.json.JsonOutput

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
    nonprod: 'PLACEHOLDER_NONPROD_HELM_IMAGE:PLACEHOLDER_HELM_IMAGE_VERSION',
    prod: 'PLACEHOLDER_PROD_HELM_IMAGE:PLACEHOLDER_HELM_IMAGE_VERSION'
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

        def repositoryDetails
        withEnv([
            "TO_CHART_REPOSITORY=${toChartRepository}",
            "AWS_REGION=${awsRegion}"
        ]) {
            repositoryDetails = sh(
                label: 'Resolve destination ECR repository',
                returnStdout: true,
                script: '''aws ecr describe-repositories \
                    --region "$AWS_REGION" \
                    --repository-names "$TO_CHART_REPOSITORY" \
                    --query 'repositories[0].[repositoryUri,imageTagMutability]' \
                    --output text'''
            ).trim()
        }
        def repositoryFields = repositoryDetails.tokenize()
        def repositoryUri = repositoryFields ? repositoryFields[0] : ''
        def repositoryMutability = repositoryFields.size() > 1 ? repositoryFields[1] : ''
        if (!repositoryUri || repositoryUri == 'None' || !repositoryUri.contains('/')) {
            error("AWS did not return a valid ECR repository URI for ${toChartRepository}")
        }
        if (repositoryMutability != 'IMMUTABLE') {
            error("Destination ECR repository ${toChartRepository} must be IMMUTABLE; got ${repositoryMutability ?: 'unknown'}")
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

        def artifactDetails
        withEnv([
            "TO_CHART_REPOSITORY=${toChartRepository}",
            "FROM_CHART_VERSION=${fromChartVersion}",
            "AWS_REGION=${awsRegion}"
        ]) {
            artifactDetails = sh(
                label: 'Verify transferred Helm artifact',
                returnStdout: true,
                script: '''aws ecr describe-images \
                    --region "$AWS_REGION" \
                    --repository-name "$TO_CHART_REPOSITORY" \
                    --image-ids "imageTag=$FROM_CHART_VERSION" \
                    --query 'imageDetails[0].[artifactMediaType,imageDigest]' \
                    --output text'''
            ).trim()
        }
        def artifactFields = artifactDetails.tokenize()
        def artifactMediaType = artifactFields ? artifactFields[0] : ''
        def artifactDigest = artifactFields.size() > 1 ? artifactFields[1] : ''
        if (artifactMediaType != 'application/vnd.cncf.helm.config.v1+json') {
            error("Unexpected ECR artifact media type for ${toChartRepository}:${fromChartVersion}: ${artifactMediaType ?: 'unknown'}")
        }
        if (!(artifactDigest ==~ /sha256:[0-9a-f]{64}/)) {
            error("AWS did not return a valid digest for ${toChartRepository}:${fromChartVersion}")
        }

        def promotionRecord = [
            schemaVersion: 'artemis.apache.org/ecr-promotion/v1',
            source: "${fromRepo.replaceAll('/+$', '')}/${fromChart}:${fromChartVersion}",
            destinationRepository: repositoryUri,
            destinationTag: fromChartVersion,
            destinationDigest: artifactDigest,
            artifactMediaType: artifactMediaType,
            destinationTagMutability: repositoryMutability,
            jenkinsBuild: env.BUILD_URL ?: ''
        ]
        writeFile(
            file: 'helm-promotion-record.json',
            text: JsonOutput.prettyPrint(JsonOutput.toJson(promotionRecord)) + '\n'
        )
        archiveArtifacts artifacts: 'helm-promotion-record.json', fingerprint: true
        echo "Verified ${toChartRepository}:${fromChartVersion}@${artifactDigest}"
    }
}
