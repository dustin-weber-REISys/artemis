{{- define "artemis-ha.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "artemis-ha.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "artemis-ha.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "artemis-ha.crName" -}}
{{- include "artemis-ha.fullname" . -}}
{{- end -}}

{{- define "artemis-ha.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "artemis-ha.labels" -}}
helm.sh/chart: {{ include "artemis-ha.chart" . }}
app.kubernetes.io/name: {{ include "artemis-ha.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: artemis-ha
{{ with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "artemis-ha.selectorLabels" -}}
app.kubernetes.io/name: {{ include "artemis-ha.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "artemis-ha.brokerSelector" -}}
application: {{ include "artemis-ha.crName" . }}-app
ActiveMQArtemis: {{ include "artemis-ha.crName" . }}
{{- end -}}

{{/*
The embedded console is an always-on chart invariant. Keeping its operand port
here makes Services, NetworkPolicies, and all probes consume the same value.
*/}}
{{- define "artemis-ha.consolePort" -}}
8161
{{- end -}}

{{/*
The operator-managed cluster connector uses its own internal acceptor on 61616.
This is peer traffic, independent of the configurable client acceptors.
*/}}
{{- define "artemis-ha.brokerPeerPort" -}}
61616
{{- end -}}

{{/*
The pinned operand's JGroups TCP stack uses 7800 for DNS_PING discovery and
7900 for FD_SOCK2 failure detection. Both are broker-to-broker traffic and
must remain reachable through the chart's default-deny NetworkPolicy.
*/}}
{{- define "artemis-ha.jgroupsDiscoveryPort" -}}
7800
{{- end -}}

{{- define "artemis-ha.jgroupsFailureDetectionPort" -}}
7900
{{- end -}}

{{- define "artemis-ha.serviceAccountName" -}}
{{- if .Values.security.serviceAccount.create -}}
{{- default (include "artemis-ha.fullname" .) .Values.security.serviceAccount.name -}}
{{- else -}}
{{- required "security.serviceAccount.name is required when security.serviceAccount.create is false" .Values.security.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "artemis-ha.monitoringNamespace" -}}
{{- default .Release.Namespace .Values.monitoring.serviceMonitor.namespace -}}
{{- end -}}

{{- define "artemis-ha.ruleNamespace" -}}
{{- default .Release.Namespace .Values.monitoring.prometheusRule.namespace -}}
{{- end -}}
