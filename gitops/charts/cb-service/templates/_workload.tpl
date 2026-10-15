{{/* Everything one service needs. A service chart's only template is: {{ include "cb-service.all" . }} */}}
{{- define "cb-service.all" -}}
{{ include "cb-service.rollout" . }}
---
{{ include "cb-service.svc" . }}
---
{{ include "cb-service.hpa" . }}
---
{{ include "cb-service.pdb" . }}
{{- if (.Values.ingress | default dict).enabled }}
---
{{ include "cb-service.ingress" . }}
{{- end }}
{{- end }}

{{- define "cb-service.rollout" -}}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ .Values.service }}
  labels:
    {{- include "cb-service.labels" . | nindent 4 }}
spec:
  # No spec.replicas: the HPA owns the count (and pre-warm owns HPA minReplicas, which the
  # ApplicationSet tells Argo CD to ignore).
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: {{ .Values.service }}
  strategy:
    canary:
      steps:
        - setWeight: 10
        {{- if .Values.analysis.enabled }}
        - analysis:
            templates:
              - templateName: cb-canary-health
                clusterScope: true
            args:
              - name: service
                value: {{ .Values.service }}
              - name: cell
                value: {{ .Values.cell }}
        {{- else }}
        # Analysis needs the in-cell Prometheus (Week 5); until then the canary pauses instead.
        - pause: { duration: 2m }
        {{- end }}
        - setWeight: 50
        - pause: { duration: 5m }
        - setWeight: 100
  template:
    metadata:
      labels:
        {{- include "cb-service.labels" . | nindent 8 }}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/path: /actuator/prometheus
        prometheus.io/port: "{{ .Values.managementPort }}"
    spec:
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 40     # > Spring's graceful shutdown (30 s)
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: {{ .Values.service }}
      containers:
        - name: app
          image: {{ include "cb-service.image" . | quote }}
          ports:
            - { name: http, containerPort: {{ .Values.port }} }
            - { name: management, containerPort: {{ .Values.managementPort }} }
          env:
            - { name: CB_CELL, value: {{ .Values.cell | quote }} }
            - { name: MANAGEMENT_PORT, value: {{ .Values.managementPort | quote }} }
            - { name: JAVA_TOOL_OPTIONS, value: {{ .Values.javaToolOptions | quote }} }
            {{- if .Values.database }}
            - { name: SPRING_DATASOURCE_URL, valueFrom: { secretKeyRef: { name: cell-db, key: jdbcUrl } } }
            - { name: SPRING_DATASOURCE_USERNAME, valueFrom: { secretKeyRef: { name: cell-db, key: username } } }
            - { name: SPRING_DATASOURCE_PASSWORD, valueFrom: { secretKeyRef: { name: cell-db, key: password } } }
            {{- end }}
            {{- if .Values.cache }}
            - { name: VALKEY_URL, valueFrom: { secretKeyRef: { name: cell-cache, key: url } } }
            {{- end }}
            {{- range $name, $value := .Values.env }}
            - { name: {{ $name }}, value: {{ tpl (toString $value) $ | quote }} }
            {{- end }}
          resources:
            {{- include "cb-service.resources" . | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
          # Probes hit the management port: actuator never shares the port the gateway routes to.
          startupProbe:                     # JVM start on 2 GiB nodes: allow 60 s before liveness counts
            httpGet: { path: /actuator/health/liveness, port: management }
            periodSeconds: 2
            failureThreshold: 30
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: management }
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: management }
            periodSeconds: 5
      volumes:
        - { name: tmp, emptyDir: { sizeLimit: 64Mi } }
{{- end }}

{{- define "cb-service.svc" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.service }}
  labels:
    {{- include "cb-service.labels" . | nindent 4 }}
spec:
  selector:
    app: {{ .Values.service }}
  ports:
    - { name: http, port: {{ .Values.port }}, targetPort: http }
    - { name: management, port: {{ .Values.managementPort }}, targetPort: management }
{{- end }}

{{- define "cb-service.hpa" -}}
{{- if gt (int .Values.replicas.min) (int .Values.replicas.max) }}
{{- fail (printf "replicas.min (%v) > replicas.max (%v)" .Values.replicas.min .Values.replicas.max) }}
{{- end -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .Values.service }}
  labels:
    {{- include "cb-service.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: argoproj.io/v1alpha1
    kind: Rollout
    name: {{ .Values.service }}
  minReplicas: {{ .Values.replicas.min }}
  # Sized so this cell can take 100% of traffic:
  #   maxReplicas = ceil(1.2 × peak_gateway_rps_all_cells × fanout / per_pod_rps)
  # per_pod_rps is not measured yet (k6, Week 5): see gitops/cells/<cell>/capacity.yaml.
  maxReplicas: {{ .Values.replicas.max }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 65 }
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies: [{ type: Percent, value: 100, periodSeconds: 30 }]
    scaleDown:
      stabilizationWindowSeconds: 300
{{- end }}

{{- define "cb-service.pdb" -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .Values.service }}
  labels:
    {{- include "cb-service.labels" . | nindent 4 }}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: {{ .Values.service }}
{{- end }}

{{- define "cb-service.ingress" -}}
{{- $domain := required "domain is set by gitops/global/values.yaml" .Values.domain -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Values.service }}
  labels:
    {{- include "cb-service.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: {{ required "ingress.className is set by the cell" .Values.ingress.className }}
  tls:
    # Cloudflare Origin CA certificate (Full strict): written by Ansible origin_tls on budget cells.
    - secretName: origin-tls
      hosts:
        - app.{{ $domain }}
        - admin-{{ .Values.cloud }}.{{ $domain }}
  rules:
    # app: the Cloudflare load balancer. admin-<cloud>: a proxied record straight at this cell's
    # origin, behind Cloudflare Access (the lease allocator must reach one specific cell).
    {{- range list (printf "app.%s" $domain) (printf "admin-%s.%s" .Values.cloud $domain) }}
    - host: {{ . }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ $.Values.service }}
                port: { name: http }
    {{- end }}
{{- end }}
