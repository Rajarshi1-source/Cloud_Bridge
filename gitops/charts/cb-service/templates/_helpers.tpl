{{/*
Values contract (service chart values.yaml + gitops/global/values.yaml + gitops/cells/<cell>/values.yaml
+ gitops/releases/<ring>.yaml, merged in that order by Argo CD):
  service, port, managementPort        from the service chart
  replicas.{min,max}                   service chart; a budget cell may override (replica floors)
  resources                            service chart; resourceOverrides.<service> wins (budget cells)
  database / cache                     true = inject cell-db / cell-cache Secret env
  env                                  extra plain env; values pass through tpl (may use .Values)
  cell, cloud, imageRegistryMirror     from the cell
  images.<service>                     from the ring file: <user>/cb-<service>@sha256:<digest>
*/}}

{{- define "cb-service.labels" -}}
app: {{ .Values.service }}
cb-cell: {{ required "cell is set by gitops/cells/<cell>/values.yaml" .Values.cell }}
app.kubernetes.io/name: {{ .Values.service }}
app.kubernetes.io/part-of: cloudbridge
app.kubernetes.io/managed-by: argocd
{{- end }}

{{- define "cb-service.image" -}}
{{- $ref := required (printf "images.%s is set by the ring file" .Values.service) (index (.Values.images | default dict) .Values.service) -}}
{{- if not (regexMatch "@sha256:[0-9a-f]{64}$" $ref) -}}
{{- fail (printf "images.%s must be pinned by digest, got %q" .Values.service $ref) -}}
{{- end -}}
{{- printf "%s/%s" (required "imageRegistryMirror is set by the cell" .Values.imageRegistryMirror) (trimPrefix "docker.io/" $ref) -}}
{{- end }}

{{- define "cb-service.resources" -}}
{{- $override := index (.Values.resourceOverrides | default dict) .Values.service -}}
{{- toYaml (default .Values.resources $override) -}}
{{- end }}
