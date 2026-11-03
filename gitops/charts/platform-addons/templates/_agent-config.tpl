{{- define "platform-addons.agentConfig" -}}
{{- $o := .Values.observability -}}
{{- $port := ternary "" (printf ":%v" $o.remoteWrite.edgePort) (empty $o.remoteWrite.edgePort) -}}
global:
  scrape_interval: 15s
  external_labels:
    cb_cell: {{ .Values.cell | quote }}
    cb_cloud: {{ required "cloud is set by the cell values" .Values.cloud | quote }}
    cb_env: {{ last (splitList "-" .Values.cell) | quote }}
    cb_profile: {{ ternary "budget" "managed" .Values.budgetData.enabled | quote }}

scrape_configs:
  - job_name: apps
    honor_labels: true                # the services' own cb_cell and service tags win
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [cb-app]
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: service
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod

  # Delivery dashboard: syncs and rollout phases, from their controllers' metrics ports.
  - job_name: argocd
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [{{ .Values.argocdNamespace }}]
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
        action: keep
        regex: argocd-application-controller
      - source_labels: [__address__]
        regex: ([^:]+)(?::\d+)?
        replacement: $1:8082
        target_label: __address__
    metric_relabel_configs:
      - source_labels: [__name__]
        action: keep
        regex: argocd_app_info|argocd_app_sync_total

  - job_name: argo-rollouts
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [argo-rollouts]
    relabel_configs:
      - source_labels: [__address__]
        regex: ([^:]+)(?::\d+)?
        replacement: $1:8090
        target_label: __address__
    metric_relabel_configs:
      - source_labels: [__name__]
        action: keep
        regex: rollout_info|analysis_run_info

remote_write:
  - url: {{ printf "https://metrics.%s%s/api/v1/write" .Values.domain $port | quote }}
    http_headers:
      CF-Access-Client-Id:
        files: [/etc/metrics-writer/client-id]
      CF-Access-Client-Secret:
        files: [/etc/metrics-writer/client-secret]
    {{- with $o.remoteWrite.caFile }}
    tls_config:
      ca_file: {{ . | quote }}
    {{- end }}
    queue_config:
      capacity: 10000
      max_samples_per_send: 2000
    write_relabel_configs:
      - source_labels: [__name__]
        regex: go_.*|process_.*|jvm_gc_pause_seconds_bucket
        action: drop                  # keeps the free-tier-sized receiver small
{{- end -}}
