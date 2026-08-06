{{/*
Common names and labels. Keep selectors stable across chart upgrades because a
StatefulSet selector is immutable after creation.
*/}}
{{- define "zookeeper.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "zookeeper.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "zookeeper.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "zookeeper.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "zookeeper.labels" -}}
helm.sh/chart: {{ include "zookeeper.chart" . }}
{{ include "zookeeper.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "zookeeper.selectorLabels" -}}
app.kubernetes.io/name: {{ include "zookeeper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "zookeeper.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "zookeeper.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "zookeeper.image" -}}
{{- printf "%s:%s@%s" (trimSuffix "/" .Values.image.repository) .Values.image.tag .Values.image.digest -}}
{{- end -}}

{{- define "zookeeper.headlessServiceName" -}}
{{- printf "%s-headless" (include "zookeeper.fullname" .) -}}
{{- end -}}

{{- define "zookeeper.clientServiceName" -}}
{{- printf "%s-client" (include "zookeeper.fullname" .) -}}
{{- end -}}

{{- define "zookeeper.configMapName" -}}
{{- printf "%s-config" (include "zookeeper.fullname" .) -}}
{{- end -}}

{{- define "zookeeper.zooServers" -}}
{{- range $i, $_ := until (int .Values.replicaCount) -}}
{{- if $i }} {{ end -}}server.{{ add $i 1 }}={{ include "zookeeper.fullname" $ }}-{{ $i }}.{{ include "zookeeper.headlessServiceName" $ }}.{{ $.Release.Namespace }}.svc.cluster.local:2888:3888;2181
{{- end -}}
{{- end -}}

{{- define "zookeeper.configServerLines" -}}
{{- $replicas := int .Values.replicaCount -}}
{{- range $i, $_ := until $replicas -}}
server.{{ add $i 1 }}={{ include "zookeeper.fullname" $ }}-{{ $i }}.{{ include "zookeeper.headlessServiceName" $ }}.{{ $.Release.Namespace }}.svc.cluster.local:2888:3888{{ if lt (add $i 1) $replicas }}{{ "\n" }}{{ end }}
{{- end -}}
{{- end -}}

{{- define "zookeeper.tlsVolumeName" -}}tls-material{{- end -}}
{{- define "zookeeper.authVolumeName" -}}auth-material{{- end -}}
