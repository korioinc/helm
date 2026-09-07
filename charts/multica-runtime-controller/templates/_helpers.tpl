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

{{- define "multica-runtime-controller.toolsClaimName" -}}
{{- default (printf "%s-tools" (include "multica-runtime-controller.fullname" .)) .Values.environment.storage.existingClaim -}}
{{- end -}}

{{- define "multica-runtime-controller.bootstrapScript" -}}
{{- if eq .Values.environment.bootstrap.source "bundled" -}}
{{- .Files.Get "files/environments/node-providers.sh" -}}
{{- else if eq .Values.environment.bootstrap.source "inline" -}}
{{- .Values.environment.bootstrap.script -}}
{{- end -}}
{{- end -}}
{{- define "multica-runtime-controller.scriptSHA256" -}}
{{- if eq .Values.environment.bootstrap.source "configMap" -}}
{{- .Values.environment.bootstrap.configMap.sha256 -}}
{{- else -}}
{{- include "multica-runtime-controller.bootstrapScript" . | sha256sum -}}
{{- end -}}
{{- end -}}
{{- define "multica-runtime-controller.environmentInput" -}}
{{- dict "schemaVersion" 1 "coreImage" .Values.runtime.image.reference "environmentImage" .Values.environment.image.reference "platform" .Values.environment.platform "scriptSHA256" (include "multica-runtime-controller.scriptSHA256" .) "revision" .Values.environment.bootstrap.revision "providers" (.Values.environment.providers | uniq | sortAlpha) "inputs" .Values.environment.bootstrap.env | toJson -}}
{{- end -}}
{{- define "multica-runtime-controller.environmentID" -}}
{{- include "multica-runtime-controller.environmentInput" . | sha256sum -}}
{{- end -}}
{{- define "multica-runtime-controller.nodeSelector" -}}
{{- merge (dict "kubernetes.io/os" "linux" "kubernetes.io/arch" (trimPrefix "linux/" .Values.environment.platform)) .Values.scheduling.nodeSelector | toJson -}}
{{- end -}}
{{- define "multica-runtime-controller.securityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}
{{- define "multica-runtime-controller.environmentEnv" -}}
- name: MULTICA_PLATFORM
  value: {{ .Values.environment.platform | quote }}
- name: MULTICA_CORE_ROOT
  value: /opt/multica/core
- name: MULTICA_ENVIRONMENT_ROOT
  value: /opt/multica/environment
- name: MULTICA_ENVIRONMENT_INPUT_FILE
  value: /etc/multica/environment/input.json
- name: MULTICA_ENVIRONMENT_ID
  value: {{ include "multica-runtime-controller.environmentID" . | quote }}
- name: MULTICA_OWNER_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "multica-runtime-controller.identitySecretName" . }}
      key: daemon-id
{{- end -}}
{{- define "multica-runtime-controller.validateItems" -}}
{{- range . -}}
{{- if or (isAbs .path) (ne (clean .path) .path) (hasPrefix ".." .path) -}}
{{- fail "operator config volume item paths must be confined" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- define "multica-runtime-controller.validate" -}}
{{- if eq (include "multica-runtime-controller.workspaceClaimName" .) (include "multica-runtime-controller.toolsClaimName" .) -}}
{{- fail "environment.storage and workspace.storage must use different PVCs" -}}
{{- end -}}
{{- if and (or (eq .Values.environment.storage.accessMode "ReadWriteOnce") (eq .Values.workspace.storage.accessMode "ReadWriteOnce")) (empty .Values.scheduling.singleNodeName) -}}
{{- fail "scheduling.singleNodeName is required for ReadWriteOnce storage" -}}
{{- end -}}
{{- range $key, $expected := dict "kubernetes.io/os" "linux" "kubernetes.io/arch" (trimPrefix "linux/" .Values.environment.platform) -}}
{{- if and (hasKey $.Values.scheduling.nodeSelector $key) (ne (index $.Values.scheduling.nodeSelector $key) $expected) -}}
{{- fail (printf "scheduling.nodeSelector %s conflicts with environment.platform" $key) -}}
{{- end -}}
{{- end -}}
{{- $volumes := dict -}}
{{- range .Values.operator.configVolumes -}}
{{- if or (hasKey $volumes .name) (hasPrefix "runtime-" .name) (has .name (list "core" "tools" "workspace" "tmp" "bootstrap-tmp" "agent-home" "run" "environment-config" "bootstrap-script" "controller-token" "kube-api-access" "worker-config")) -}}{{- fail "operator.configVolumes has duplicate or reserved volume name" -}}{{- end -}}
{{- $_ := set $volumes .name true -}}
{{- with .secret -}}{{- include "multica-runtime-controller.validateItems" .items -}}{{- end -}}
{{- with .configMap -}}{{- include "multica-runtime-controller.validateItems" .items -}}{{- end -}}
{{- with .projected -}}
{{- range .sources -}}
{{- with .secret -}}{{- include "multica-runtime-controller.validateItems" .items -}}{{- end -}}
{{- with .configMap -}}{{- include "multica-runtime-controller.validateItems" .items -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $mountPaths := list -}}
{{- $mounted := dict -}}
{{- range .Values.operator.configMounts -}}
{{- if not (hasKey $volumes .name) -}}{{- fail "operator.configMounts references an unknown configVolume" -}}{{- end -}}
{{- $path := clean .mountPath -}}
{{- if or (ne $path .mountPath) (not (hasPrefix "/home/multica/agents/" $path)) (eq $path "/home/multica/agents/.multica/config.json") (hasPrefix "/home/multica/agents/.multica/config.json/" $path) (eq $path "/home/multica/agents/.multica/pi-sessions") (hasPrefix "/home/multica/agents/.multica/pi-sessions/" $path) (eq $path "/home/multica/agents/.codex/skills") (hasPrefix "/home/multica/agents/.codex/skills/" $path) (eq $path "/home/multica/agents/.pi/agent/sessions") (hasPrefix "/home/multica/agents/.pi/agent/sessions/" $path) -}}
{{- fail "operator.configMounts must copy to canonical native HOME paths and cannot override runtime or session state" -}}
{{- end -}}
{{- range $other := $mountPaths -}}
{{- if or (eq $path $other) (hasPrefix (printf "%s/" $path) $other) (hasPrefix (printf "%s/" $other) $path) -}}{{- fail "operator.configMounts paths cannot overlap" -}}{{- end -}}
{{- end -}}
{{- $mountPaths = append $mountPaths $path -}}
{{- $_ := set $mounted .name true -}}
{{- if and .subPath (or (isAbs .subPath) (ne (clean .subPath) .subPath) (hasPrefix ".." .subPath)) -}}{{- fail "operator.configMounts subPath must be confined" -}}{{- end -}}
{{- end -}}
{{- range .Values.operator.configVolumes -}}
{{- if not (hasKey $mounted .name) -}}{{- fail "operator.configVolumes must be mounted" -}}{{- end -}}
{{- end -}}
{{- range .Values.operator.env -}}
{{- if contains "$(" (default "" .value) -}}{{- fail "operator.env values are literal; use valueFrom for key aliases" -}}{{- end -}}
{{- if or (hasPrefix "MULTICA_" .name) (hasPrefix "POD_" .name) (hasPrefix "ENV_" .name) (has .name (list "HOME" "PATH" "TMPDIR" "WORKSPACE" "ENV_ROOT")) -}}{{- fail "operator.env cannot override runtime control variables" -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- define "multica-runtime-controller.workerConfig" -}}
{{ dict "coreImage" .Values.runtime.image.reference "corePullPolicy" .Values.runtime.image.pullPolicy "environmentImage" .Values.environment.image.reference "environmentPullPolicy" .Values.environment.image.pullPolicy "platform" .Values.environment.platform "environmentID" (include "multica-runtime-controller.environmentID" .) "toolsClaim" (include "multica-runtime-controller.toolsClaimName" .) "workspaceClaim" (include "multica-runtime-controller.workspaceClaimName" .) "toolsAccessMode" .Values.environment.storage.accessMode "workspaceAccessMode" .Values.workspace.storage.accessMode "serviceAccount" (printf "%s-worker" (include "multica-runtime-controller.fullname" .)) "imagePullSecrets" .Values.imagePullSecrets "nodeSelector" (include "multica-runtime-controller.nodeSelector" . | fromJson) "tolerations" .Values.scheduling.tolerations "singleNodeName" .Values.scheduling.singleNodeName "resources" .Values.worker.resources "taskDeadlineSeconds" .Values.worker.taskDeadline "terminationGraceSeconds" .Values.worker.terminationGraceSeconds "configVolumes" .Values.operator.configVolumes "configMounts" .Values.operator.configMounts "configEnvFrom" .Values.operator.envFrom "configEnv" .Values.operator.env | toJson }}
{{- end -}}
