{{- define "frontrow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "frontrow.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains (include "frontrow.name" .) .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "frontrow.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "frontrow.selectorLabels" -}}
app.kubernetes.io/name: {{ include "frontrow.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "frontrow.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "frontrow.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: frontrow
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "frontrow.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "frontrow.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* repository:tag@digest when a digest is known, otherwise repository:tag. */}}
{{- define "frontrow.image" -}}
{{- $repo := required "image.repository is required (set by the web pipeline)" .Values.image.repository -}}
{{- $tag := required "image.tag is required (set by the web pipeline)" .Values.image.tag -}}
{{- if eq $tag "latest" -}}
{{- fail "image.tag must be an immutable tag, not 'latest'" -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s:%s@%s" $repo $tag .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end -}}

{{/* Lowest replica count the workload can run with. */}}
{{- define "frontrow.minReplicas" -}}
{{- if .Values.autoscaling.enabled -}}
{{- .Values.autoscaling.minReplicas -}}
{{- else -}}
{{- .Values.replicaCount -}}
{{- end -}}
{{- end -}}
