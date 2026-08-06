{{/*
Override the upstream chart's globally named label helpers. The upstream 2.2.0
chart has no common-label value and uses selectorLabels for the Deployment pod
template, so the required labels must be stable for the life of the release.
*/}}
{{- define "arkmq-org-broker-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "arkmq-org-broker-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- with .Values.global.requiredLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "arkmq-org-broker-operator.labels" -}}
helm.sh/chart: {{ include "arkmq-org-broker-operator.chart" . }}
{{ include "arkmq-org-broker-operator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
