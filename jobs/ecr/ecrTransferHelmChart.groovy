pipelineJob('ECR-TransferHelmChart') {
    parameters {
        stringParam {
            name('FROM_REPO')
            defaultValue('')
            description('Source OCI namespace, including the oci:// prefix')
            trim(true)
        }
        stringParam {
            name('FROM_CHART')
            defaultValue('')
            description('Source Helm chart name')
            trim(true)
        }
        stringParam {
            name('FROM_CHART_VERSION')
            defaultValue('')
            description('Exact Helm chart version to transfer')
            trim(true)
        }
        choiceParam {
            name('TO_REPO')
            choices(['nonprod', 'prod'])
            description('Destination ECR environment')
        }
        stringParam {
            name('TO_CHART_REPOSITORY')
            defaultValue('')
            description('Exact destination ECR repository; its final segment must match the chart name')
            trim(true)
        }
    }

    definition {
        cpsScm {
            scriptPath('resources/ecr/ecrHelmChartTransfer.groovy')
            lightweight(true)
            scm {
                git {
                    remote {
                        url('PLACEHOLDER_SCM_URL')
                        credentials('PLACEHOLDER_SCM_CREDENTIALS_ID')
                    }
                    branch('PLACEHOLDER_SCM_BRANCH')
                }
            }
        }
    }
}
