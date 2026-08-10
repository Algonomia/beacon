{{/*
Expand the name of the chart.
*/}}
{{- define "beacon.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "beacon.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "beacon.labels" -}}
helm.sh/chart: {{ include "beacon.chart" . }}
{{ include "beacon.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "beacon.selectorLabels" -}}
app.kubernetes.io/name: {{ include "beacon.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component-specific labels
*/}}
{{- define "beacon.componentLabels" -}}
{{- $component := . -}}
app: {{ $component }}
component: {{ $component }}
{{- end }}

{{/*
Namespace
*/}}
{{- define "beacon.namespace" -}}
{{- .Values.global.namespace | default "default" }}
{{- end }}

{{/*
Whether Prometheus needs Kubernetes SD, and so a ServiceAccount and list/watch RBAC.
*/}}
{{- define "beacon.prometheus.kubeSD" -}}
{{- if or .Values.discovery.enabled .Values.postgresMonitoring.enabled -}}true{{- end -}}
{{- end }}

{{/*
Config checksum
*/}}
{{- define "beacon.configChecksum" -}}
{{- toYaml . | sha256sum }}
{{- end }}
