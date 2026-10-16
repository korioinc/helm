{{- define "magpie.apiPort" -}}3425{{- end -}}
{{- define "magpie.webuiPort" -}}3430{{- end -}}

{{- define "magpie.webuiName" -}}
{{- printf "%s-webui" (include "magpie.fullname" . | trunc 57 | trimSuffix "-") -}}
{{- end -}}

{{- define "magpie.webuiSecretName" -}}
{{- default (include "magpie.webuiName" .) .Values.auth.existingSecret -}}
{{- end -}}

{{- define "magpie.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "magpie.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains (include "magpie.name" .) .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "magpie.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "magpie.selectorLabels" -}}
app.kubernetes.io/name: {{ include "magpie.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "magpie.labels" -}}
{{ include "magpie.selectorLabels" . }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
{{- if .Values.image.tag }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "magpie.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (required "Set image.tag or image.digest in the installation values" .Values.image.tag) -}}
{{- end -}}
{{- end -}}
