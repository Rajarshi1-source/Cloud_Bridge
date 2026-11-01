# CloudBridge GitOps Delivery — Starter Code

## Contents
1. docker-compose.yml
2. Service Dockerfile
3. Root ApplicationSet template
4. Charts: the `cb-service` library, a service chart, platform-addons
5. Global + per-cell values, ring files, capacity file
6. `tools/bump_ring.py`
7. `.github/workflows/ci-app.yml`
8. `.github/workflows/ring-promote.yml`

Every GitHub action is pinned to a full commit SHA (`@<sha>` placeholders below); Dependabot keeps them current. The March 2025 `tj-actions/changed-files` compromise — tags moved to malicious commits — is the one-line reason.

---

## 1. docker-compose.yml

```yaml
name: cloudbridge

x-java: &java
  restart: unless-stopped
  depends_on:
    postgres:
      condition: service_healthy
    valkey:
      condition: service_healthy

x-java-env: &java-env
  JAVA_TOOL_OPTIONS: "-XX:MaxRAMPercentage=70 -XX:+UseSerialGC -Xss512k"
  SPRING_PROFILES_ACTIVE: local
  CB_CELL: cb-local-dev
  VALKEY_URL: redis://valkey:6379

services:
  api-gateway:
    <<: *java
    build: ./services/api-gateway
    ports: ["8080:8080"]
    environment:
      <<: *java-env
      ORDER_URL: http://order-service:8081
      INVENTORY_URL: http://inventory-service:8082

  order-service:
    <<: *java
    build: ./services/order-service
    environment:
      <<: *java-env
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/cell
      SPRING_DATASOURCE_USERNAME: cell
      SPRING_DATASOURCE_PASSWORD: cell

  inventory-service:
    <<: *java
    build: ./services/inventory-service
    environment:
      <<: *java-env
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/cell
      SPRING_DATASOURCE_USERNAME: cell
      SPRING_DATASOURCE_PASSWORD: cell

  postgres:
    image: postgres:18.4-alpine
    environment:
      POSTGRES_USER: cell
      POSTGRES_PASSWORD: cell
      POSTGRES_DB: cell
    volumes:
      - pg:/var/lib/postgresql
      - ./control-plane/migrations/00-create-cp-db.sql:/docker-entrypoint-initdb.d/00-cp.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U cell"]
      interval: 5s
      retries: 10

  valkey:
    image: valkey/valkey:9.0-alpine
    command: ["valkey-server", "--save", "", "--appendonly", "no"]
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 5s
      retries: 10

  control-plane-api:
    build: ./control-plane
    environment:
      DATABASE_URL: postgresql://cell:cell@postgres:5432/controlplane
      VALKEY_URL: redis://valkey:6379
      COST_SOURCE: fixtures
    depends_on:
      postgres:
        condition: service_healthy

  dashboard:
    build: ./control-plane/dashboard
    ports: ["3000:3000"]
    environment:
      CP_API_URL: http://control-plane-api:8000

  prometheus:
    image: prom/prometheus:v3.14.0
    command: ["--config.file=/etc/prometheus/prometheus.yml", "--web.enable-remote-write-receiver"]
    volumes: ["./observability/prometheus:/etc/prometheus:ro"]
    ports: ["9090:9090"]

  grafana:
    image: grafana/grafana:13.2.0
    ports: ["3001:3000"]
    volumes: ["./observability/grafana/provisioning:/etc/grafana/provisioning:ro"]

  k6:
    image: grafana/k6:1.0.0
    profiles: ["load"]
    volumes: ["./load:/scripts:ro"]
    command: ["run", "/scripts/cell.js"]

volumes:
  pg: {}
```
`00-create-cp-db.sql` contains `CREATE DATABASE controlplane;` — the cell DB and control-plane DB share one Postgres locally, never in the cloud.

## 2. Service Dockerfile

```dockerfile
# syntax=docker/dockerfile:1.7
FROM eclipse-temurin:21-jdk-noble AS build
WORKDIR /src
COPY mvnw pom.xml ./
COPY .mvn .mvn
RUN --mount=type=cache,target=/root/.m2 ./mvnw -q dependency:go-offline
COPY src src
RUN --mount=type=cache,target=/root/.m2 ./mvnw -q -DskipTests package \
 && java -Djarmode=tools -jar target/*.jar extract --layers --launcher --destination /out

# Pin the Ubuntu codename: the unpinned 21-jre tag moved to Ubuntu 26.04, which ships /usr/bin/pebble
# (a Go binary with HIGH stdlib CVEs this image never runs) and failed the Trivy gate.
FROM eclipse-temurin:21-jre-noble
RUN useradd --uid 10001 --create-home app
WORKDIR /app
COPY --from=build /out/dependencies/ ./
COPY --from=build /out/spring-boot-loader/ ./
COPY --from=build /out/snapshot-dependencies/ ./
COPY --from=build /out/application/ ./
USER 10001
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=70", "-XX:+ExitOnOutOfMemoryError", "org.springframework.boot.loader.launch.JarLauncher"]
```

## 3. Root ApplicationSet template

Validated (Week 2): `helm template` for every chart × cell, kubeconform with the Argo CRD schemas, and the `argocd_autodeploy` Molecule scenario renders this file with Ansible. **Never put a dollar-brace sequence in a comment in this file** — Terraform `templatefile()` and Ansible (with `${` as the Jinja delimiter) both try to evaluate it; the first draft did, and both renderers would have failed.

```yaml
# gitops/bootstrap/applicationset.yaml.tftpl
# Root ApplicationSet: the only thing installed into a cell besides Argo CD itself.
# One template, two renderers: Terraform templatefile() (managed cells, 20-bootstrap) and Ansible
# with dollar-brace Jinja delimiters (budget cells, role argocd_autodeploy). Both fill only the
# cell and ring placeholders; Argo CD's own {{.app}} passes through both untouched.
# Never write a dollar-brace sequence in a comment here: both renderers would try to evaluate it.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cloudbridge-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - list:
        elements:
          - app: platform-addons
          - app: api-gateway
          - app: order-service
          - app: inventory-service
  template:
    metadata:
      name: "{{.app}}"
      labels:
        cb-cell: ${cell}
      # Compare only the fields Argo CD applies (server-side). The default client-side diff marks
      # Rollouts OutOfSync forever (the HPA owns spec.replicas through the scale subresource) and the
      # postgres StatefulSet too (the API server fills in volumeClaimTemplates). Found by the twin.
      annotations:
        argocd.argoproj.io/compare-options: ServerSideDiff=true
    spec:
      project: default
      sources:
        - repoURL: https://github.com/Rajarshi1-source/Cloud_Bridge.git
          targetRevision: main
          path: "gitops/charts/{{.app}}"
          helm:
            valueFiles:
              - "$values/gitops/global/values.yaml"
              - "$values/gitops/cells/${cell}/values.yaml"
              - "$values/gitops/releases/${ring}.yaml"
        - repoURL: https://github.com/Rajarshi1-source/Cloud_Bridge.git
          targetRevision: main
          ref: values
      destination:
        server: https://kubernetes.default.svc
        namespace: cb-app
      # Pre-warm (ansible prewarm.yml) raises HPA minReplicas before an evacuation; without this,
      # selfHeal would revert it within seconds.
      ignoreDifferences:
        - group: autoscaling
          kind: HorizontalPodAutoscaler
          jsonPointers:
            - /spec/minReplicas
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
          - RespectIgnoreDifferences=true
          - SkipDryRunOnMissingResource=true   # Rollout CRDs arrive with platform-addons
        retry:
          limit: 10
          backoff: { duration: 15s, factor: 2, maxDuration: 5m }
```

Terraform side (managed cells, `20-bootstrap`, Week 3):
```hcl
resource "kubernetes_manifest" "root_appset" {
  manifest = yamldecode(templatefile("${path.module}/../../../../gitops/bootstrap/applicationset.yaml.tftpl", {
    cell = var.cell_name
    ring = var.cloud == "gcp" ? "ring-canary" : "ring-main"
  }))
  depends_on = [helm_release.argocd]
}
```

## 4. Charts

The three services share one **library chart** (`gitops/charts/cb-service`, `type: library`); each service chart is a `Chart.yaml` with a `file://../cb-service` dependency, a `values.yaml`, and one template line `{{ include "cb-service.all" . }}`. One copy of the probes, security context and spread rules means the services can't drift apart. Argo CD builds `file://` dependencies itself; `charts/*/charts/` is git-ignored.

Facts the first draft got wrong:
- **Probes target the management port (9080)**, where actuator lives (`management.server.port`), not the service port.
- **No `spec.replicas` on the Rollout**: the HPA owns the count.
- **Analysis needs a query-capable Prometheus in the cell** (Week 5). Until then `analysis.enabled: false` and the canary pauses instead; an analysis step against a missing Prometheus aborts every rollout.
- **Images must be digests**: the image helper `fail`s on a tag, so a bad ring file breaks rendering, not a deploy.
- **Budget cells need resource overrides** (`resourceOverrides.<service>`): the default requests (~1.1 GiB) don't fit a 2 GiB VM next to k3s, Argo CD, Traefik, Rollouts, Postgres and Valkey.
- Traefik, Argo Rollouts and the budget Postgres/Valkey are owned by Argo CD through `platform-addons` (child Applications pin the upstream chart versions). k3s's bundled Traefik is disabled.
- Valkey uses `volatile-lru`: `allkeys-lru` could evict the `stream:cell-events` outbox stream (it has no TTL).

```yaml
# gitops/charts/cb-service/templates/_helpers.tpl
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
```

```yaml
# gitops/charts/cb-service/templates/_workload.tpl
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
```

```yaml
# gitops/charts/order-service/Chart.yaml
apiVersion: v2
name: order-service
description: "Orders: idempotent claim, reserve, commit saga and the outbox relay."
type: application
version: 0.1.0
dependencies:
  - name: cb-service
    version: 0.1.0
    repository: file://../cb-service
```

```yaml
# gitops/charts/order-service/values.yaml
# Service defaults. Per-cloud values come only from gitops/cells/<cell>/values.yaml,
# image digests only from gitops/releases/<ring>.yaml.
service: order-service
port: 8081
managementPort: 9080
replicas:
  min: 2
  max: 10             # TODO(Week 5): derive from k6 per-pod RPS (see the HPA comment)
resources:
  requests: { cpu: 300m, memory: 448Mi }
  limits: { cpu: "1", memory: 640Mi }
javaToolOptions: "-XX:+UseSerialGC -Xss512k"
database: true
cache: true
env:
  INVENTORY_URL: "http://inventory-service:8082"
ingress:
  enabled: false
analysis:
  enabled: false        # Week 5 turns this on with the in-cell Prometheus
```

```yaml
# gitops/charts/platform-addons/values.yaml
# Defaults. Cells override only what gitops/cells/<cell>/values.yaml is allowed to differ in.
cell: ""
cloud: ""
domain: ""

# Child Applications (argo-rollouts, traefik) live in Argo CD's namespace and pull upstream charts.
argocdNamespace: argocd

addons:
  argoRollouts:
    chartVersion: 2.43.7        # Argo Rollouts v1.10.1
  traefik:
    chartVersion: 41.7.1        # Traefik v3.7.14; installed only where ingress.className is traefik

ingress:
  className: ""

# Canary analysis queries an in-cell Prometheus, which arrives with observability in Week 5.
analysis:
  enabled: false
  prometheusAddress: http://prometheus-query.monitoring:9090
  maxErrorRate: "0.01"
  maxP95Seconds: "0.3"

network:
  # Where ingress traffic to the gateway comes from: the controller's namespace (k3s Traefik) or
  # load balancer CIDRs (managed cells set these in their cell values).
  ingressNamespaces: []
  ingressCidrs: []
  # Managed data services (RDS / Cloud SQL / ElastiCache / Memorystore) live outside the cluster.
  dataCidrs: []
  monitoringNamespace: monitoring

# Budget profile only: Postgres and Valkey run in the cluster. Credentials come from the cell-db /
# cell-cache Secrets that Ansible writes on the VM; Argo CD never sees a password.
budgetData:
  enabled: false
  postgres:
    image: postgres:18.4-alpine
    storage: 5Gi
    resources:
      requests: { cpu: 100m, memory: 160Mi }
      limits: { memory: 256Mi }
  valkey:
    image: valkey/valkey:9.0-alpine
    maxmemory: 48mb
    resources:
      requests: { cpu: 25m, memory: 48Mi }
      limits: { memory: 96Mi }
```

```yaml
# gitops/charts/platform-addons/templates/networkpolicies.yaml
{{- /*
cb-app is default-deny in both directions; every flow below is named. Enforced by k3s's built-in
policy controller, GKE Dataplane V2 and the EKS VPC CNI network policy agent alike.
*/ -}}
{{- $apps := list "api-gateway" "order-service" "inventory-service" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - ports:
        - { port: 53, protocol: UDP }
        - { port: 53, protocol: TCP }
---
# Public traffic reaches only the gateway, and only from the ingress controller / load balancer.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ingress-to-gateway
spec:
  podSelector:
    matchLabels: { app: api-gateway }
  policyTypes: [Ingress]
  ingress:
    - ports: [{ port: 8080 }]
      from:
        {{- range .Values.network.ingressNamespaces }}
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: {{ . }} }
        {{- end }}
        {{- range .Values.network.ingressCidrs }}
        - ipBlock: { cidr: {{ . }} }
        {{- end }}
        {{- if and (empty .Values.network.ingressNamespaces) (empty .Values.network.ingressCidrs) }}
        {{- fail "network.ingressNamespaces or network.ingressCidrs must be set by the cell" }}
        {{- end }}
---
# Gateway → order (routes + readiness probe for /healthz/cell) and → inventory (GET /inventory).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gateway-egress
spec:
  podSelector:
    matchLabels: { app: api-gateway }
  policyTypes: [Egress]
  egress:
    - to: [{ podSelector: { matchLabels: { app: order-service } } }]
      ports: [{ port: 8081 }, { port: 9080 }]
    - to: [{ podSelector: { matchLabels: { app: inventory-service } } }]
      ports: [{ port: 8082 }]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: order-ingress
spec:
  podSelector:
    matchLabels: { app: order-service }
  policyTypes: [Ingress]
  ingress:
    - from: [{ podSelector: { matchLabels: { app: api-gateway } } }]
      ports: [{ port: 8081 }, { port: 9080 }]
---
# Order → inventory: POST /reservations is internal and never routed by the gateway.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: order-egress
spec:
  podSelector:
    matchLabels: { app: order-service }
  policyTypes: [Egress]
  egress:
    - to: [{ podSelector: { matchLabels: { app: inventory-service } } }]
      ports: [{ port: 8082 }]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: inventory-ingress
spec:
  podSelector:
    matchLabels: { app: inventory-service }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: api-gateway } }
        - podSelector: { matchLabels: { app: order-service } }
      ports: [{ port: 8082 }]
---
# Apps → the cell's Postgres and Valkey (in-cluster on budget, CIDRs on managed).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: apps-to-data
spec:
  podSelector:
    matchExpressions: [{ key: app, operator: In, values: {{ toJson $apps }} }]
  policyTypes: [Egress]
  egress:
    {{- if .Values.budgetData.enabled }}
    - to: [{ podSelector: { matchLabels: { app: postgres } } }]
      ports: [{ port: 5432 }]
    - to: [{ podSelector: { matchLabels: { app: valkey } } }]
      ports: [{ port: 6379 }]
    {{- end }}
    {{- range .Values.network.dataCidrs }}
    - to: [{ ipBlock: { cidr: {{ . }} } }]
      ports: [{ port: 5432 }, { port: 6379 }]
    {{- end }}
{{- if .Values.budgetData.enabled }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: data-ingress
spec:
  podSelector:
    matchExpressions: [{ key: app, operator: In, values: [postgres, valkey] }]
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchExpressions: [{ key: app, operator: In, values: {{ toJson $apps }} }]
{{- end }}
---
# Metrics on the management port, for the in-cell Prometheus agent only (Week 5).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: metrics-from-monitoring
spec:
  podSelector:
    matchExpressions: [{ key: app, operator: In, values: {{ toJson $apps }} }]
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: {{ .Values.network.monitoringNamespace }} }
      ports: [{ port: 9080 }]
```

```yaml
# gitops/charts/platform-addons/templates/addon-applications.yaml
{{- /*
Third-party add-ons as child Argo CD Applications (app of apps): Argo CD owns them like everything
else, and their versions are pinned here, so a parity check can compare them across cells.
*/ -}}
{{- define "platform-addons.appSync" -}}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true        # large CRDs exceed the client-side last-applied annotation limit
  retry:
    limit: 10
    backoff: { duration: 15s, factor: 2, maxDuration: 5m }
{{- end }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: {{ .Values.argocdNamespace }}
  labels: { cb-cell: {{ required "cell is set by the cell values" .Values.cell }} }
spec:
  project: default
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-rollouts
    targetRevision: {{ .Values.addons.argoRollouts.chartVersion | quote }}
    helm:
      valuesObject:
        controller:
          replicas: 1               # one controller per cell is enough; a restart only pauses rollouts
          resources:
            requests: { cpu: 25m, memory: 64Mi }
            limits: { memory: 160Mi }
        dashboard:
          enabled: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argo-rollouts
  {{- include "platform-addons.appSync" . | nindent 2 }}
{{- if eq .Values.ingress.className "traefik" }}
---
# k3s ships Traefik, but the k3s_server role disables it: Argo CD installs it here instead, so the
# ingress controller has one owner and a pinned version like every other add-on.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: {{ .Values.argocdNamespace }}
  labels: { cb-cell: {{ .Values.cell }} }
spec:
  project: default
  source:
    repoURL: https://traefik.github.io/charts
    chart: traefik
    targetRevision: {{ .Values.addons.traefik.chartVersion | quote }}
    helm:
      valuesObject:
        ingressClass:
          enabled: true
          isDefaultClass: true
        ports:
          web:
            expose:
              default: false        # origins accept 443 only (Cloudflare Full strict)
        service:
          type: LoadBalancer        # k3s ServiceLB binds 443 on the VM's address
        resources:
          requests: { cpu: 25m, memory: 48Mi }
          limits: { memory: 128Mi }
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  {{- include "platform-addons.appSync" . | nindent 2 }}
{{- end }}
```

Also in `platform-addons`: `analysis-template.yaml` (the `ClusterAnalysisTemplate`, rendered only when `analysis.enabled`) and `budget-data.yaml` (Postgres StatefulSet on k3s local-path storage, Valkey Deployment; both restricted-PSS compliant, credentials from the `cell-db` / `cell-cache` Secrets Ansible writes).

## 5. Global + per-cell values, ring files, capacity

Three value files, merged in order: `gitops/global/values.yaml` (shared; Terraform reads `domain` from it too), `gitops/cells/<cell>/values.yaml`, `gitops/releases/<ring>.yaml`.

```yaml
# gitops/global/values.yaml
# Values every cell shares. Terraform reads `domain` from this file too (global/30-traffic), so the
# Cloudflare hostnames and the Ingress hosts can't disagree.
domain: cloudbridge.example     # REPLACE with your Cloudflare zone before the first apply
```

```yaml
# gitops/cells/cb-aws-budget/values.yaml
# The ONLY per-cloud app config. Allowed to differ between cells: cell, cloud, ingress class and
# annotations, imageRegistryMirror, secretStore, network sources, and the budget profile's replica
# floors, resource overrides and in-cluster data. Anything else is parity drift.
cell: cb-aws-budget
cloud: aws
# k3s registries.yaml authenticates every Docker Hub pull with a token, so pods pull by digest from
# docker.io without anonymous rate limits. Managed cells use ECR pull-through / Artifact Registry.
imageRegistryMirror: docker.io
secretStore: ansible (from AWS Secrets Manager)
ingress:
  className: traefik
network:
  ingressNamespaces: [traefik]
budgetData:
  enabled: true
# 2 GiB VM shared with k3s, Argo CD, Traefik, Rollouts, Postgres and Valkey.
replicas:
  min: 1
  max: 2
resourceOverrides:
  api-gateway:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: "1", memory: 384Mi }
  order-service:
    requests: { cpu: 100m, memory: 288Mi }
    limits: { cpu: "1", memory: 416Mi }
  inventory-service:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: "1", memory: 384Mi }
```

```yaml
# gitops/releases/ring-canary.yaml
# GCP cell (canary ring): bot PRs land here first.
# Bot-managed by tools/bump_ring.py. Digests only: a tag can move, a digest is what was scanned and signed.
images:
  api-gateway: rickyenrico01/cb-api-gateway@sha256:c98a71aacc99e669cce1167a167da2f75af90c31aa06ad53154b8fa7a1530d8a
  order-service: rickyenrico01/cb-order-service@sha256:c8622e4acf3916c3216382a7ecab026d714de9858b2bd2b71bd282bd4eeaecbc
  inventory-service: rickyenrico01/cb-inventory-service@sha256:96b43689d19512b4899f02ac006d455820bfdd543162b757e828e5aba02ff100
releasedAt: "2026-10-15T08:01:30Z"
commit: 9da9c01
```

```yaml
# gitops/cells/cb-gcp-budget/capacity.yaml
# Per-pod RPS at p95 < 300 ms and errors < 0.5%, measured with k6 against this cell (Week 5).
# Not measured yet: the capacity check refuses to evacuate into a cell whose numbers are 0.
measuredAt: null
perPodRps:
  api-gateway: 0
  order-service: 0
  inventory-service: 0
fanout:                   # downstream calls per gateway request
  order-service: 1
  inventory-service: 2
```

## 6. tools/bump_ring.py

Keeps the ring file's comment header, refuses unknown services and non-digest refs, and validates that every service still has a digest after the bump.

```python
# tools/bump_ring.py
#!/usr/bin/env python3
"""Update a release ring file with image digests.

New build (ci-app.yml, after main publishes):
    DOCKERHUB_USER=me bump_ring.py --ring ring-canary --digests digests.env
Promotion (ring-promote.yml, after the canary soak):
    bump_ring.py --ring ring-main --from-ring ring-canary

digests.env holds one `service=sha256:<64 hex>` per line. The file's leading comment block is kept.
"""
import argparse
import datetime
import os
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASES = ROOT / "gitops" / "releases"
SERVICES = ("api-gateway", "order-service", "inventory-service")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
REF = re.compile(r"^[a-z0-9][a-z0-9_.-]*/cb-[a-z-]+@sha256:[0-9a-f]{64}$")


def read_ring(name: str) -> tuple[str, dict]:
    text = (RELEASES / f"{name}.yaml").read_text(encoding="utf-8")
    header = "".join(line for line in text.splitlines(keepends=True) if line.startswith("#"))
    return header, yaml.safe_load(text) or {}


def parse_digests(path: str) -> dict[str, str]:
    found = {}
    for line in pathlib.Path(path).read_text(encoding="utf-8").split():
        svc, _, digest = line.partition("=")
        if svc not in SERVICES:
            sys.exit(f"unknown service {svc!r}; expected one of {SERVICES}")
        if not DIGEST.match(digest):
            sys.exit(f"bad digest for {svc}: {digest!r}")
        found[svc] = digest
    return found


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ring", required=True, choices=["ring-canary", "ring-main"])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--digests", help="service=sha256:... lines from the build job")
    src.add_argument("--from-ring", choices=["ring-canary", "ring-main"], help="copy another ring (promotion)")
    a = ap.parse_args()

    header, doc = read_ring(a.ring)
    images = dict(doc.get("images") or {})

    if a.from_ring:
        if a.from_ring == a.ring:
            sys.exit("--from-ring must differ from --ring")
        _, source = read_ring(a.from_ring)
        images = dict(source["images"])
        doc["commit"] = source.get("commit")
    else:
        user = os.environ.get("DOCKERHUB_USER", "").strip()
        if not user:
            sys.exit("DOCKERHUB_USER is not set")
        for svc, digest in parse_digests(a.digests).items():
            images[svc] = f"{user}/cb-{svc}@{digest}"
        doc["commit"] = os.environ.get("GITHUB_SHA", "")[:7] or doc.get("commit")

    missing = [s for s in SERVICES if not REF.match(images.get(s, ""))]
    if missing:
        sys.exit(f"ring {a.ring} would have no valid digest for: {', '.join(missing)}")

    doc["images"] = {s: images[s] for s in SERVICES}
    doc["releasedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = RELEASES / f"{a.ring}.yaml"
    out.write_text(header + yaml.safe_dump(doc, sort_keys=False), encoding="utf-8", newline="\n")
    print(f"updated {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
```

## 7. .github/workflows/ci-app.yml

The build job below is the implemented, actionlint-clean workflow (SHAs resolved 14 Oct 2026; Dependabot keeps them current). Points the earlier draft got wrong:
- **PR builds use `load: true`, and the docker exporter can't carry attestations**, so `provenance`/`sbom` must be off on PRs (`'false'`) and on only for the pushed image. Otherwise every PR build fails.
- `vars.DOCKERHUB_USER` is empty until configured (and on forks), which makes an invalid tag (`docker.io//cb-…`); fall back to a placeholder.
- Least privilege: the workflow is `contents: read`; only the build job gets `id-token: write` (cosign keyless). `persist-credentials: false` on checkout.
- Untrusted-looking values (`steps.build.outputs.digest`, matrix values) go through `env:` into `run:`, never `${{ }}` inside the script.
- **A PR opened with `GITHUB_TOKEN` triggers no workflows**, so a required `ci-gate` check never reports and the release PR can't merge. Use a fine-grained PAT (`CB_BOT_TOKEN`); the fallback to `github.token` needs "Allow GitHub Actions to create and approve pull requests" and a close/reopen.

```yaml
# .github/workflows/ci-app.yml
# Build, test, scan, sign and publish the cell services.
# PR: verify (unit + Testcontainers ITs) and a local image build + Trivy scan, nothing pushed.
# main: the same, then push to Docker Hub, attach SBOM + provenance, cosign keyless sign BY DIGEST,
#       and upload each digest as an artifact; then open a release PR that bumps
#       gitops/releases/ring-canary.yaml (the GCP cell). Merging it is the deploy.
# Repository setup: variable DOCKERHUB_USER, secret DOCKERHUB_TOKEN (Docker Hub access token), and
# optionally secret CB_BOT_TOKEN: a fine-grained PAT (this repo; Contents + Pull requests: read/write).
# Without it the job falls back to GITHUB_TOKEN (enable "Allow GitHub Actions to create and approve
# pull requests"); such a PR triggers no workflows, so close and reopen it once to run ci-gate.
# Every action is pinned to a full commit SHA (tag comment for humans); Dependabot bumps them.
name: app

on:
  pull_request:
    paths: ["services/**", ".github/workflows/ci-app.yml"]
  push:
    branches: [main]
    paths: ["services/**", ".github/workflows/ci-app.yml"]

permissions:
  contents: read

concurrency:
  group: app-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    permissions:
      contents: read
      id-token: write # cosign keyless signing (Sigstore OIDC); no long-lived signing key
    strategy:
      fail-fast: false
      matrix:
        service: [api-gateway, order-service, inventory-service]
    env:
      IMAGE: docker.io/${{ vars.DOCKERHUB_USER || 'cloudbridge' }}/cb-${{ matrix.service }}
      PUBLISH: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - uses: actions/setup-java@de7274f081f381c8f8158605e0321c36c376e2e6 # v6.0.1
        with:
          distribution: temurin
          java-version: "21"
          cache: maven

      - name: Unit + Testcontainers ITs
        working-directory: services/${{ matrix.service }}
        run: ./mvnw -B -ntp verify

      - name: Test reports
        if: failure()
        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with:
          name: test-reports-${{ matrix.service }}
          path: |
            services/${{ matrix.service }}/target/surefire-reports/
            services/${{ matrix.service }}/target/failsafe-reports/
          retention-days: 7

      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1

      - uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
        if: env.PUBLISH == 'true'
        with:
          username: ${{ vars.DOCKERHUB_USER }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - id: build
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: services/${{ matrix.service }}
          tags: ${{ env.IMAGE }}:${{ github.sha }}
          # PRs load the image into the runner's Docker for scanning. The docker exporter can't
          # carry attestations, so SBOM + provenance are attached only to the pushed image.
          load: ${{ env.PUBLISH != 'true' }}
          push: ${{ env.PUBLISH == 'true' }}
          provenance: ${{ env.PUBLISH == 'true' && 'mode=max' || 'false' }}
          sbom: ${{ env.PUBLISH == 'true' }}
          cache-from: type=gha,scope=${{ matrix.service }}
          cache-to: type=gha,mode=max,scope=${{ matrix.service }}

      - name: Trivy image scan (HIGH/CRITICAL with a fix available fails the build)
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          image-ref: ${{ env.IMAGE }}:${{ github.sha }}
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"

      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2
        if: env.PUBLISH == 'true'

      - name: Sign by digest (keyless)
        if: env.PUBLISH == 'true'
        env:
          DIGEST: ${{ steps.build.outputs.digest }}
        run: cosign sign --yes "${IMAGE}@${DIGEST}"

      - name: Save digest
        if: env.PUBLISH == 'true'
        env:
          SERVICE: ${{ matrix.service }}
          DIGEST: ${{ steps.build.outputs.digest }}
        run: echo "${SERVICE}=${DIGEST}" > "digest-${SERVICE}.env"

      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        if: env.PUBLISH == 'true'
        with:
          name: digest-${{ matrix.service }}
          path: digest-${{ matrix.service }}.env
          retention-days: 30

  promote-canary:
    needs: build
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    permissions:
      contents: write # only used when CB_BOT_TOKEN is absent (GITHUB_TOKEN fallback)
      pull-requests: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          pattern: digest-*
          merge-multiple: true

      # Ubuntu 24.04's system Python refuses pip installs (PEP 668); use a managed interpreter.
      - uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0
        with:
          python-version: "3.14"

      - name: Bump ring-canary to this build's digests
        env:
          DOCKERHUB_USER: ${{ vars.DOCKERHUB_USER }}
        run: |
          cat digest-*.env > "$RUNNER_TEMP/digests.env"
          rm digest-*.env
          python -m pip install --quiet pyyaml==6.0.3
          python tools/bump_ring.py --ring ring-canary --digests "$RUNNER_TEMP/digests.env"

      - uses: peter-evans/create-pull-request@5f6978faf089d4d20b00c7766989d076bb2fc7f1 # v8.1.1
        with:
          token: ${{ secrets.CB_BOT_TOKEN || github.token }}
          branch: release/canary
          delete-branch: true
          add-paths: gitops/releases/ring-canary.yaml
          commit-message: "release(canary): ${{ github.sha }}"
          title: "release(canary): ${{ github.sha }} → GCP ring"
          labels: release,ring-canary
          body: |
            Bumps `gitops/releases/ring-canary.yaml` to the images built, scanned and signed from ${{ github.sha }}.
            Merging deploys them to the GCP cell only (Argo CD, then the Rollouts canary). AWS follows
            through `ring-main` after the soak — one cloud at a time.
```

## 8. .github/workflows/ring-promote.yml

```yaml
name: ring-promote
on:
  repository_dispatch:
    types: [canary-healthy]      # sent by Argo CD notifications when the GCP Rollout is Healthy
  workflow_dispatch: {}

permissions:
  contents: write
  pull-requests: write

jobs:
  promote:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - name: Soak 30 minutes
        run: sleep 1800
      - name: Gate on SLO burn and relative latency
        run: |
          q() { curl -fsS -G "${{ vars.CB_PROM_URL }}/api/v1/query" \
                 -H "Authorization: Bearer ${{ secrets.CB_PROM_TOKEN }}" --data-urlencode "query=$1" \
                 | jq -r '.data.result[0].value[1] // "0"'; }
          burn=$(q 'sum(rate(http_server_requests_seconds_count{cb_cell="cb-gcp-prod",service="api-gateway",status=~"5.."}[30m])) / sum(rate(http_server_requests_seconds_count{cb_cell="cb-gcp-prod",service="api-gateway"}[30m])) / 0.005')
          ratio=$(q 'cb:latency_p95:5m{cb_cell="cb-gcp-prod",service="api-gateway"} / cb:latency_p95:5m{cb_cell="cb-aws-prod",service="api-gateway"}')
          echo "burn=$burn ratio=$ratio"
          awk -v b="$burn" -v r="$ratio" 'BEGIN { exit !(b < 1 && r < 1.10) }'
      - run: pip install pyyaml && python3 tools/bump_ring.py --ring ring-main --from-ring ring-canary
        env:
          DOCKERHUB_USER: ${{ vars.DOCKERHUB_USER }}
      - uses: peter-evans/create-pull-request@<sha>
        with:
          branch: release/main-${{ github.run_id }}
          title: "release(main): promote canary digests → AWS ring"
          labels: release,ring-main
```
