{{- define "beacon.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "beacon.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "beacon.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "beacon.labels" -}}
helm.sh/chart: {{ include "beacon.chart" . }}
{{ include "beacon.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "beacon.selectorLabels" -}}
app.kubernetes.io/name: {{ include "beacon.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "beacon.componentLabels" -}}
{{- $component := . -}}
app: {{ $component }}
component: {{ $component }}
{{- end }}

{{- define "beacon.namespace" -}}
{{- .Values.global.namespace | default "default" }}
{{- end }}

{{/*
Whether Prometheus needs Kubernetes SD, and so a ServiceAccount and list/watch RBAC.
*/}}
{{- define "beacon.prometheus.kubeSD" -}}
{{- if or .Values.discovery.enabled .Values.postgresMonitoring.enabled .Values.containerMonitoring.enabled -}}true{{- end -}}
{{- end }}

{{- define "beacon.configChecksum" -}}
{{- toYaml . | sha256sum }}
{{- end }}
