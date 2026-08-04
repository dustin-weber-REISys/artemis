@Library('PLACEHOLDER_SHARED_LIB') _

import PLACEHOLDER_ECR_IMPORT

def fromRepo = params.FROM_REPO ?: ''
def fromChart = params.FROM_CHART ?: ''
def fromChartVersion = params.FROM_CHART_VERSION ?: ''
def toRepo = params.TO_REPO ?: 'nonprod'
def toChartRepository = params.TO_CHART_REPOSITORY ?: ''
def awsRegion = 'us-east-1'

def agentLabels = [
    nonprod: 'PLACEHOLDER_NONPROD_AGENT_LABEL',
    prod: 'PLACEHOLDER_PROD_AGENT_LABEL'
]
def agentLabel = agentLabels[toRepo]
if (!agentLabel) {
    error("Unsupported TO_REPO value: ${toRepo}")
}

node(agentLabel) {
    stage('Checkout') {
        checkout scm
    }

    stage('Transfer Helm Chart') {
        // Keep destination account selection consistent with ECR-TransferImage.
        ECR.login(this, toRepo)

        withEnv([
            "FROM_REPO=${fromRepo}",
            "FROM_CHART=${fromChart}",
            "FROM_CHART_VERSION=${fromChartVersion}",
            "TO_CHART_REPOSITORY=${toChartRepository}",
            "AWS_REGION=${awsRegion}"
        ]) {
            sh(
                label: 'Pull, push, and verify Helm chart',
                script: 'bash resources/ecr/transfer-helm-chart.sh'
            )
        }
    }
}
