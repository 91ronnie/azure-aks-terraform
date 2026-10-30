{{- define "cratedigger.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cratedigger.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains (include "cratedigger.name" .) .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "cratedigger.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "cratedigger.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cratedigger.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "cratedigger.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "cratedigger.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: cratedigger
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "cratedigger.secretName" -}}
{{- printf "%s-secrets" (include "cratedigger.fullname" .) -}}
{{- end -}}

{{/* repository:tag@digest when a digest is known, otherwise repository:tag. */}}
{{- define "cratedigger.image" -}}
{{- $repo := required "image.repository is required (set by the pipeline)" .Values.image.repository -}}
{{- $tag := required "image.tag is required (set by the pipeline)" .Values.image.tag -}}
{{- if eq $tag "latest" -}}
{{- fail "image.tag must be an immutable tag, not 'latest'" -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s:%s@%s" $repo $tag .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end -}}

{{- define "cratedigger.databaseUrl" -}}
{{- $url := required "database.url is required (terraform output cratedigger.database_url)" .Values.database.url -}}
{{- if regexMatch "://[^/@]+:[^/@]+@" $url -}}
{{- fail "database.url must not contain a password (Entra ID auth is used)" -}}
{{- end -}}
{{- $url -}}
{{- end -}}

{{/* Shared container fields for the init and app containers. */}}
{{- define "cratedigger.containerCommon" -}}
image: {{ include "cratedigger.image" . | quote }}
imagePullPolicy: {{ .Values.image.pullPolicy }}
env:
  - name: DATABASE_URL
    value: {{ include "cratedigger.databaseUrl" . | quote }}
  # A file path (the web app keeps OAuth tokens in PostgreSQL).
  - name: SPOTIFY_TOKEN_CACHE_PATH
    value: /app/data/.spotify_cache
envFrom:
  - configMapRef:
      name: {{ include "cratedigger.fullname" . }}
  - secretRef:
      name: {{ include "cratedigger.secretName" . }}
securityContext:
  {{- toYaml .Values.securityContext | nindent 2 }}
volumeMounts:
  - name: tmp
    mountPath: /tmp
  - name: data
    mountPath: /app/data
  - name: exports
    mountPath: /app/spotify_exports
  - name: keyvault
    mountPath: /mnt/secrets
    readOnly: true
{{- end -}}
