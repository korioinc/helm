{{- define "multica-runtime-controller.discoverKubernetesAPIEndpoints" -}}
{{- $service := lookup "v1" "Service" "default" "kubernetes" -}}
{{- if not $service -}}
{{- fail "Kubernetes API discovery requires cluster access: use Helm install/upgrade or helm template --dry-run=server; offline rendering requires networkPolicy.blockKubernetesAPI=false" -}}
{{- end -}}
{{- $serviceTargets := list -}}
{{- range $ip := default (list $service.spec.clusterIP) $service.spec.clusterIPs -}}
{{- if or (not $ip) (eq $ip "None") -}}
{{- fail "default/kubernetes must have an API Service IP for worker egress protection" -}}
{{- end -}}
{{- range $port := $service.spec.ports -}}
{{- if eq (default "TCP" $port.protocol) "TCP" -}}
{{- $serviceTargets = append $serviceTargets (dict "ip" $ip "port" (int $port.port)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $backendTargets := list -}}
{{- $slices := lookup "discovery.k8s.io/v1" "EndpointSlice" "default" "" -}}
{{- range $slice := $slices.items -}}
{{- if eq (index (default (dict) $slice.metadata.labels) "kubernetes.io/service-name") "kubernetes" -}}
{{- if not (has $slice.addressType (list "IPv4" "IPv6")) -}}
{{- fail "Kubernetes API EndpointSlices must use IPv4 or IPv6 addresses for worker egress protection" -}}
{{- end -}}
{{- if not $slice.ports -}}
{{- fail "Kubernetes API EndpointSlice has no ports; cannot determine API egress targets" -}}
{{- end -}}
{{- range $port := $slice.ports -}}
{{- if eq (default "TCP" $port.protocol) "TCP" -}}
{{- if not $port.port -}}
{{- fail "Kubernetes API EndpointSlice has no TCP port; cannot determine API egress targets" -}}
{{- end -}}
{{- range $endpoint := $slice.endpoints -}}
{{- range $ip := $endpoint.addresses -}}
{{- $backendTargets = append $backendTargets (dict "ip" $ip "port" (int $port.port)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if or (not $serviceTargets) (not $backendTargets) -}}
{{- fail "Kubernetes API discovery requires both Service and EndpointSlice TCP targets; cannot enable API egress protection without them" -}}
{{- end -}}
{{- concat $serviceTargets $backendTargets | uniq | toJson -}}
{{- end -}}

{{- define "multica-runtime-controller.egressPeers" -}}
{{- $peers := list -}}
{{- range $family := list "ipv4" "ipv6" -}}
{{- $root := ternary "::/0" "0.0.0.0/0" (eq $family "ipv6") -}}
{{- $except := list -}}
{{- $blocked := false -}}
{{- range $ -}}
{{- if eq (contains ":" .) (eq $family "ipv6") -}}
{{- if hasSuffix "/0" . -}}
{{- if ne . $root -}}
{{- fail "blockedEgressCIDRs must use canonical 0.0.0.0/0 or ::/0 for a whole address family" -}}
{{- end -}}
{{- $blocked = true -}}
{{- else -}}
{{- $except = append $except . -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $blocked -}}
{{- $block := dict "cidr" $root -}}
{{- if $except -}}
{{- $_ := set $block "except" ($except | uniq | sortAlpha) -}}
{{- end -}}
{{- $peers = append $peers (dict "ipBlock" $block) -}}
{{- end -}}
{{- end -}}
{{- $peers | toJson -}}
{{- end -}}
