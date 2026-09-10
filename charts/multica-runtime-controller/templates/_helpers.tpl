{{- define "multica-runtime-controller.name" -}}
multica-runtime-controller
{{- end }}

{{- define "multica-runtime-controller.fullname" -}}
{{- $name := include "multica-runtime-controller.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}
{{- define "multica-runtime-controller.labels" -}}
app.kubernetes.io/name: {{ include "multica-runtime-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "multica-runtime-controller.workspaceClaimName" -}}
{{- default (printf "%s-workspace" (include "multica-runtime-controller.fullname" .)) .Values.workspace.storage.existingClaim -}}
{{- end }}

{{- define "multica-runtime-controller.identitySecretName" -}}
{{- printf "%s-identity" (include "multica-runtime-controller.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "multica-runtime-controller.daemonProxyServiceName" -}}
{{- printf "%s-daemon-proxy" (include "multica-runtime-controller.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "multica-runtime-controller.nodeSelector" -}}
{{- merge (dict "kubernetes.io/os" "linux" "kubernetes.io/arch" (trimPrefix "linux/" .Values.platform)) .Values.scheduling.nodeSelector | toJson -}}
{{- end -}}
{{- define "multica-runtime-controller.securityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}
{{- define "multica-runtime-controller.startupSeconds" -}}
{{- $seconds := 0.0 -}}
{{- range regexFindAll "[0-9]+(\\.[0-9]+)?(ms|s|m|h)" .Values.runtime.startupTimeout -1 -}}
{{- $value := regexFind "[0-9]+(\\.[0-9]+)?" . | float64 -}}
{{- $unit := regexFind "(ms|s|m|h)$" . -}}
{{- $seconds = addf $seconds (mulf $value (index (dict "ms" 0.001 "s" 1.0 "m" 60.0 "h" 3600.0) $unit)) -}}
{{- end -}}
{{- if le $seconds 0.0 -}}{{- fail "runtime.startupTimeout must be a positive duration" -}}{{- end -}}
{{- $seconds -}}
{{- end -}}
{{- define "multica-runtime-controller.validateItems" -}}
{{- $paths := list -}}{{- $keys := dict -}}
{{- range . -}}
{{- if or (isAbs .path) (ne (clean .path) .path) (regexMatch "(^|/)\\.\\.?(/|$)" .path) -}}
{{- fail "operator config volume item paths must be canonical and confined" -}}
{{- end -}}
{{- if hasKey $keys .key -}}{{- fail "operator config volume item keys must be unique" -}}{{- end -}}
{{- $_ := set $keys .key true -}}
{{- $path := .path -}}
{{- range $other := $paths -}}
{{- if or (eq $path $other) (hasPrefix (printf "%s/" $path) $other) (hasPrefix (printf "%s/" $other) $path) -}}{{- fail "operator config volume item paths cannot overlap" -}}{{- end -}}
{{- end -}}
{{- $paths = append $paths $path -}}
{{- end -}}
{{- end -}}
{{- define "multica-runtime-controller.validate" -}}
{{- $repository := regexReplaceAll ":[^/:@]+$" (first (splitList "@" .Values.image)) "" -}}
{{- if gt (len $repository) 255 -}}{{- fail "image repository name must not exceed 255 characters" -}}{{- end -}}
{{- if and (eq .Values.workspace.storage.accessMode "ReadWriteOnce") (empty .Values.scheduling.singleNodeName) -}}
{{- fail "scheduling.singleNodeName is required for ReadWriteOnce workspace storage" -}}
{{- end -}}
{{- range $key, $expected := dict "kubernetes.io/os" "linux" "kubernetes.io/arch" (trimPrefix "linux/" .Values.platform) -}}
{{- if and (hasKey $.Values.scheduling.nodeSelector $key) (ne (index $.Values.scheduling.nodeSelector $key) $expected) -}}
{{- fail (printf "scheduling.nodeSelector %s conflicts with platform" $key) -}}
{{- end -}}
{{- end -}}
{{- $volumes := dict -}}
{{- range .Values.operator.configVolumes -}}
{{- if or (hasKey $volumes .name) (hasPrefix "runtime-" .name) (has .name (list "private" "workspace" "controller-token" "kube-api-access" "worker-config")) -}}{{- fail "operator.configVolumes has duplicate or reserved volume name" -}}{{- end -}}
{{- $_ := set $volumes .name true -}}
{{- include "multica-runtime-controller.validateItems" .configMap.items -}}
{{- end -}}
{{- $targets := list -}}{{- $sources := dict -}}{{- $mounted := dict -}}
{{- range .Values.operator.configMounts -}}
{{- if not (hasKey $volumes .name) -}}{{- fail "operator.configMounts references an unknown configVolume" -}}{{- end -}}
{{- $path := clean .mountPath -}}
{{- if or (ne $path .mountPath) (not (hasPrefix "/home/multica/agents/" $path)) -}}{{- fail "operator.configMounts must copy to canonical private HOME paths" -}}{{- end -}}
{{- range $protected := list "/home/multica/agents/.multica/config.json" "/home/multica/agents/.multica/pi-sessions" "/home/multica/agents/.pi/agent/sessions" "/home/multica/agents/.multica-runtime" -}}
{{- if or (eq $path $protected) (hasPrefix (printf "%s/" $protected) $path) -}}{{- fail "operator.configMounts cannot override runtime or session state" -}}{{- end -}}
{{- end -}}
{{- range $other := $targets -}}
{{- if or (eq $path $other) (hasPrefix (printf "%s/" $path) $other) (hasPrefix (printf "%s/" $other) $path) -}}{{- fail "operator.configMounts target paths cannot overlap" -}}{{- end -}}
{{- end -}}
{{- $targets = append $targets $path -}}
{{- $source := default "." .subPath -}}
{{- if and .subPath (or (isAbs .subPath) (ne (clean .subPath) .subPath) (regexMatch "(^|/)\\.\\.?(/|$)" .subPath)) -}}{{- fail "operator.configMounts subPath must be canonical and confined" -}}{{- end -}}
{{- range $other := default (list) (index $sources .name) -}}
{{- if or (eq $source ".") (eq $other ".") (eq $source $other) (hasPrefix (printf "%s/" $source) $other) (hasPrefix (printf "%s/" $other) $source) -}}{{- fail "operator.configMounts source paths cannot overlap within one configVolume" -}}{{- end -}}
{{- end -}}
{{- $_ := set $sources .name (append (default (list) (index $sources .name)) $source) -}}
{{- $_ := set $mounted .name true -}}
{{- end -}}
{{- range .Values.operator.configVolumes -}}
{{- if not (hasKey $mounted .name) -}}{{- fail "operator.configVolumes must have a configMount copy mapping" -}}{{- end -}}
{{- end -}}
{{- range .Values.operator.env -}}
{{- if contains "$(" (default "" .value) -}}{{- fail "operator.env values are literal; use valueFrom for key aliases" -}}{{- end -}}
{{- if or (hasPrefix "MULTICA_" .name) (hasPrefix "POD_" .name) (hasPrefix "ENV_" .name) (has .name (list "HOME" "PATH" "TMPDIR" "WORKSPACE" "ENV_ROOT")) -}}{{- fail "operator.env cannot override runtime control variables" -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- define "multica-runtime-controller.workerConfig" -}}
{{ dict "platform" .Values.platform "imagePullPolicy" .Values.imagePullPolicy "workspaceClaim" (include "multica-runtime-controller.workspaceClaimName" .) "workspaceAccessMode" .Values.workspace.storage.accessMode "serviceAccount" (printf "%s-worker" (include "multica-runtime-controller.fullname" .)) "imagePullSecrets" .Values.imagePullSecrets "nodeSelector" (include "multica-runtime-controller.nodeSelector" . | fromJson) "tolerations" .Values.scheduling.tolerations "singleNodeName" .Values.scheduling.singleNodeName "resources" .Values.worker.resources "taskDeadlineSeconds" .Values.worker.taskDeadline "terminationGraceSeconds" .Values.worker.terminationGraceSeconds "configEnvFrom" .Values.operator.envFrom "configEnv" .Values.operator.env | toJson }}
{{- end -}}
