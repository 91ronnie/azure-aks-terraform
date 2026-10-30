{{- define "frontrow-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "frontrow-api.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains (include "frontrow-api.name" .) .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "frontrow-api.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Selector labels; pass (dict "root" $ "component" "api"). */}}
{{- define "frontrow-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "frontrow-api.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "frontrow-api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
{{ include "frontrow-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .root.Values.image.tag | default .root.Chart.AppVersion | quote }}
app.kubernetes.io/part-of: frontrow
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end -}}

{{- define "frontrow-api.secretName" -}}
{{- printf "%s-secrets" (include "frontrow-api.fullname" .) -}}
{{- end -}}

{{/* Environment variable -> Key Vault secret name, required + extra. */}}
{{- define "frontrow-api.allSecrets" -}}
{{- toYaml (merge (dict) .Values.keyVault.extraSecrets .Values.keyVault.secrets) -}}
{{- end -}}

{{/* repository:tag@digest; tag is shared by both images. */}}
{{- define "frontrow-api.imageRef" -}}
{{- $repo := required (printf "%s.repository is required (set by the pipeline)" .key) .image.repository -}}
{{- $tag := required "image.tag is required (set by the pipeline)" .tag -}}
{{- if eq $tag "latest" -}}
{{- fail "image.tag must be an immutable tag, not 'latest'" -}}
{{- end -}}
{{- if .image.digest -}}
{{- printf "%s:%s@%s" $repo $tag .image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end -}}

{{- define "frontrow-api.appImage" -}}
{{- include "frontrow-api.imageRef" (dict "key" "image" "image" .Values.image "tag" .Values.image.tag) -}}
{{- end -}}

{{- define "frontrow-api.webImage" -}}
{{- include "frontrow-api.imageRef" (dict "key" "webImage" "image" .Values.webImage "tag" .Values.image.tag) -}}
{{- end -}}

{{/* Pod-level fields shared by every workload (API, workers, scheduler, job). */}}
{{- define "frontrow-api.podCommon" -}}
serviceAccountName: {{ .Values.serviceAccount.name }}
# Workload identity uses its own projected token (injected by the webhook);
# the application needs no Kubernetes API access.
automountServiceAccountToken: false
enableServiceLinks: false
securityContext:
  {{- toYaml .Values.podSecurityContext | nindent 2 }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* php container fields shared by every role; the caller adds name/command. */}}
{{- define "frontrow-api.phpContainer" -}}
image: {{ include "frontrow-api.appImage" . | quote }}
imagePullPolicy: {{ .Values.image.pullPolicy }}
envFrom:
  - configMapRef:
      name: {{ include "frontrow-api.fullname" . }}
  - secretRef:
      name: {{ include "frontrow-api.secretName" . }}
securityContext:
  {{- toYaml .Values.securityContext | nindent 2 }}
  runAsUser: {{ .Values.phpUser }}
  runAsGroup: {{ .Values.phpUser }}
volumeMounts:
  - name: tmp
    mountPath: /tmp
  - name: storage-app
    mountPath: /app/storage/app
  - name: storage-framework
    mountPath: /app/storage/framework
  - name: storage-logs
    mountPath: /app/storage/logs
  - name: keyvault
    mountPath: /mnt/secrets
    readOnly: true
  # Passport reads PASSPORT_*_KEY from the environment, but
  # app/Traits/CustomPassportTokens.php opens storage/oauth-private.key directly.
  - name: keyvault
    mountPath: /app/storage/oauth-private.key
    subPath: {{ .Values.keyVault.secrets.PASSPORT_PRIVATE_KEY }}
    readOnly: true
  - name: keyvault
    mountPath: /app/storage/oauth-public.key
    subPath: {{ .Values.keyVault.secrets.PASSPORT_PUBLIC_KEY }}
    readOnly: true
{{- end -}}

{{/* Volumes for the php container. Nothing is persistent: files go to Blob. */}}
{{- define "frontrow-api.phpVolumes" -}}
- name: tmp
  emptyDir:
    sizeLimit: 512Mi
- name: storage-app
  emptyDir:
    sizeLimit: 1Gi
- name: storage-framework
  emptyDir:
    sizeLimit: 256Mi
- name: storage-logs
  emptyDir:
    sizeLimit: 64Mi
- name: keyvault
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: {{ include "frontrow-api.fullname" . }}
{{- end -}}

{{/* Roll pods when non-secret configuration changes. */}}
{{- define "frontrow-api.podAnnotations" -}}
checksum/config: {{ include (print .Template.BasePath "/configmap.yaml") . | sha256sum }}
{{- end -}}
