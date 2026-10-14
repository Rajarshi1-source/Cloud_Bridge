# CloudBridge GitOps Delivery — Starter Code

## Contents
1. docker-compose.yml
2. Service Dockerfile
3. Root ApplicationSet template
4. Chart: values, Rollout, HPA, PDB, NetworkPolicy, AnalysisTemplate
5. Per-cell values + ring files + capacity file
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

```yaml
# gitops/bootstrap/applicationset.yaml.tftpl
# Rendered by Terraform templatefile() (managed) or Ansible with ${ } delimiters (budget).
# ${cell} and ${ring} are filled; Argo's {{.app}} passes through both renderers untouched.
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
    spec:
      project: default
      sources:
        - repoURL: https://github.com/<you>/cloudbridge
          targetRevision: main
          path: "gitops/charts/{{.app}}"
          helm:
            valueFiles:
              - "$values/gitops/cells/${cell}/values.yaml"
              - "$values/gitops/releases/${ring}.yaml"
        - repoURL: https://github.com/<you>/cloudbridge
          targetRevision: main
          ref: values
      destination:
        server: https://kubernetes.default.svc
        namespace: cb-app
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
```
Terraform side (managed cells, `20-bootstrap`):
```hcl
resource "kubernetes_manifest" "root_appset" {
  manifest = yamldecode(templatefile("${path.module}/../../../gitops/bootstrap/applicationset.yaml.tftpl", {
    cell = var.cell_name
    ring = var.cloud == "gcp" ? "ring-canary" : "ring-main"
  }))
  depends_on = [helm_release.argocd]
}
```

## 4. Chart (order-service shown; the other two differ in port, deps, resources)

```yaml
# gitops/charts/order-service/values.yaml
service: order-service
port: 8081
replicas:
  min: 2
  max: 10          # sized for 100% of traffic in this cell — see capacity.yaml
resources:
  requests: { cpu: 300m, memory: 448Mi }
  limits: { cpu: "1", memory: 640Mi }
cell: ""            # from gitops/cells/<cell>/values.yaml
cloud: ""
imageRegistryMirror: ""
secretStore: ""
images: {}          # from gitops/releases/<ring>.yaml
analysis:
  maxErrorRate: "0.01"
  maxP95Seconds: "0.3"
```

```yaml
# gitops/charts/order-service/templates/rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ .Values.service }}
  labels: { app: {{ .Values.service }}, cb-cell: {{ .Values.cell }} }
spec:
  revisionHistoryLimit: 3
  selector:
    matchLabels: { app: {{ .Values.service }} }
  strategy:
    canary:
      steps:
        - setWeight: 10
        - analysis:
            templates: [{ templateName: cb-canary-health }]
            args: [{ name: service, value: {{ .Values.service }} }, { name: cell, value: {{ .Values.cell }} }]
        - setWeight: 50
        - pause: { duration: 5m }
        - setWeight: 100
  template:
    metadata:
      labels: { app: {{ .Values.service }}, cb-cell: {{ .Values.cell }} }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/path: /actuator/prometheus
        prometheus.io/port: "{{ .Values.port }}"
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app: {{ .Values.service }} }
      containers:
        - name: app
          image: "{{ .Values.imageRegistryMirror }}/{{ index .Values.images .Values.service }}"
          ports: [{ containerPort: {{ .Values.port }} }]
          env:
            - { name: CB_CELL, value: {{ .Values.cell | quote }} }
            - { name: SPRING_DATASOURCE_URL, valueFrom: { secretKeyRef: { name: cell-db, key: jdbcUrl } } }
            - { name: SPRING_DATASOURCE_USERNAME, valueFrom: { secretKeyRef: { name: cell-db, key: username } } }
            - { name: SPRING_DATASOURCE_PASSWORD, valueFrom: { secretKeyRef: { name: cell-db, key: password } } }
            - { name: VALKEY_URL, valueFrom: { secretKeyRef: { name: cell-cache, key: url } } }
          resources: {{- toYaml .Values.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts: [{ name: tmp, mountPath: /tmp }]
          startupProbe:
            httpGet: { path: /actuator/health/liveness, port: {{ .Values.port }} }
            periodSeconds: 2
            failureThreshold: 30
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: {{ .Values.port }} }
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: {{ .Values.port }} }
            periodSeconds: 5
      volumes: [{ name: tmp, emptyDir: {} }]
```
`images` values hold `docker.io/<you>/cb-order-service@sha256:…`; the template prefixes the cell's mirror (on the mirror the path is `<mirror-prefix>/<you>/cb-order-service@sha256:…` — strip `docker.io/` in `bump_ring.py` so both forms work).

```yaml
# gitops/charts/order-service/templates/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .Values.service }}
spec:
  scaleTargetRef:
    apiVersion: argoproj.io/v1alpha1
    kind: Rollout
    name: {{ .Values.service }}
  minReplicas: {{ .Values.replicas.min }}
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
```

```yaml
# gitops/charts/order-service/templates/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .Values.service }}
spec:
  minAvailable: 1
  selector:
    matchLabels: { app: {{ .Values.service }} }
```

```yaml
# gitops/charts/platform-addons/templates/networkpolicy-default-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: cb-app
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: cb-app
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - ports: [{ port: 53, protocol: UDP }, { port: 53, protocol: TCP }]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gateway-to-backends
  namespace: cb-app
spec:
  podSelector:
    matchExpressions: [{ key: app, operator: In, values: [order-service, inventory-service] }]
  policyTypes: [Ingress]
  ingress:
    - from: [{ podSelector: { matchLabels: { app: api-gateway } } }]
```
Plus: ingress-controller → gateway, apps → DB/cache CIDRs (from cell values), Prometheus agent → app metrics ports.

```yaml
# gitops/charts/platform-addons/templates/analysis-template.yaml
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: cb-canary-health
spec:
  args:
    - name: service
    - name: cell
  metrics:
    - name: error-rate
      interval: 1m
      count: 5
      failureLimit: 1
      successCondition: result[0] < 0.01
      provider:
        prometheus:
          address: http://prometheus-agent-query.monitoring:9090   # in-cell query endpoint (see observability skill)
          query: |
            sum(rate(http_server_requests_seconds_count{service="{{args.service}}",status=~"5.."}[2m]))
            / sum(rate(http_server_requests_seconds_count{service="{{args.service}}"}[2m]))
    - name: p95
      interval: 1m
      count: 5
      failureLimit: 1
      successCondition: result[0] < 0.3
      provider:
        prometheus:
          address: http://prometheus-agent-query.monitoring:9090
          query: |
            histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{service="{{args.service}}"}[2m])))
```
Use `kind: ClusterAnalysisTemplate` (cluster-scoped) or change the Rollout step to `clusterScope: true` — keep the two consistent. Prometheus in agent mode can't answer queries, so each cell runs a small query-capable Prometheus for Rollouts analysis (short retention) alongside the agent — or point Rollouts at the central receiver with a `cb_cell` filter. Pick one and document it.

## 5. Per-cell values, ring files, capacity

```yaml
# gitops/cells/cb-gcp-prod/values.yaml
cell: cb-gcp-prod
cloud: gcp
imageRegistryMirror: asia-south1-docker.pkg.dev/cloudbridge-prod/dockerhub
secretStore: gcp-secret-manager
ingress:
  className: gce
  annotations:
    kubernetes.io/ingress.global-static-ip-name: cb-gcp-prod-ingress
```

```yaml
# gitops/cells/cb-aws-budget/values.yaml
cell: cb-aws-budget
cloud: aws
imageRegistryMirror: docker.io
secretStore: aws-secrets-manager
ingress:
  className: traefik
replicas:
  min: 1
  max: 2
```

```yaml
# gitops/releases/ring-canary.yaml   (bot-managed)
images:
  api-gateway: <you>/cb-api-gateway@sha256:0000000000000000000000000000000000000000000000000000000000000000
  order-service: <you>/cb-order-service@sha256:0000000000000000000000000000000000000000000000000000000000000000
  inventory-service: <you>/cb-inventory-service@sha256:0000000000000000000000000000000000000000000000000000000000000000
releasedAt: "2026-10-08T10:00:00Z"
commit: 0000000
```

```yaml
# gitops/cells/cb-gcp-prod/capacity.yaml  — measured with k6 (p95 < 300 ms, error < 0.5%)
measuredAt: "2026-11-01"
perPodRps:
  api-gateway: 0          # fill from your load test
  order-service: 0
  inventory-service: 0
fanout:                   # downstream calls per gateway request
  order-service: 1
  inventory-service: 2
```

## 6. tools/bump_ring.py

```python
#!/usr/bin/env python3
"""Update a ring file with new image digests. Usage:
   bump_ring.py --ring ring-canary --digests digests.env [--from-ring ring-canary]"""
import argparse, datetime, os, pathlib, re, sys
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ring", required=True, choices=["ring-canary", "ring-main"])
    ap.add_argument("--digests", help="lines of service=sha256:... from the build job")
    ap.add_argument("--from-ring", help="copy images from another ring (promotion)")
    a = ap.parse_args()

    path = ROOT / "gitops" / "releases" / f"{a.ring}.yaml"
    doc = yaml.safe_load(path.read_text()) or {"images": {}}
    user = os.environ["DOCKERHUB_USER"]

    if a.from_ring:
        src = yaml.safe_load((ROOT / "gitops" / "releases" / f"{a.from_ring}.yaml").read_text())
        doc["images"] = dict(src["images"])
        doc["commit"] = src.get("commit")
    else:
        for line in pathlib.Path(a.digests).read_text().split():
            svc, digest = line.split("=", 1)
            if not DIGEST.match(digest):
                sys.exit(f"bad digest for {svc}: {digest}")
            doc["images"][svc] = f"{user}/cb-{svc}@{digest}"
        doc["commit"] = os.environ.get("GITHUB_SHA", "")[:7]

    doc["releasedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    path.write_text(yaml.safe_dump(doc, sort_keys=False))
    print(f"updated {path}")

if __name__ == "__main__":
    main()
```

## 7. .github/workflows/ci-app.yml

The build job below is the implemented, actionlint-clean workflow (SHAs resolved 14 Oct 2026; Dependabot keeps them current). Points the earlier draft got wrong:
- **PR builds use `load: true`, and the docker exporter can't carry attestations**, so `provenance`/`sbom` must be off on PRs (`'false'`) and on only for the pushed image. Otherwise every PR build fails.
- `vars.DOCKERHUB_USER` is empty until configured (and on forks), which makes an invalid tag (`docker.io//cb-…`); fall back to a placeholder.
- Least privilege: the workflow is `contents: read`; only the build job gets `id-token: write` (cosign keyless). `persist-credentials: false` on checkout.
- Untrusted-looking values (`steps.build.outputs.digest`, matrix values) go through `env:` into `run:`, never `${{ }}` inside the script.

```yaml
# Build, test, scan, sign and publish the cell services.
# PR: verify (unit + Testcontainers ITs) and a local image build + Trivy scan, nothing pushed.
# main: the same, then push to Docker Hub, attach SBOM + provenance, cosign keyless sign BY DIGEST,
#       and upload each digest as an artifact (the canary-ring bump job arrives with gitops/ in Week 2).
# Repository setup: variable DOCKERHUB_USER, secret DOCKERHUB_TOKEN (Docker Hub access token).
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

  # Added in Week 2, once gitops/releases/ and tools/bump_ring.py exist:
  promote-canary:
    needs: build
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: actions/download-artifact@<sha> # pin like the others
        with:
          pattern: digest-*
          merge-multiple: true
      - run: cat digest-*.env > digests.env && pip install pyyaml && python3 tools/bump_ring.py --ring ring-canary --digests digests.env
        env:
          DOCKERHUB_USER: ${{ vars.DOCKERHUB_USER }}
      - uses: peter-evans/create-pull-request@<sha> # pin like the others
        with:
          branch: release/canary-${{ github.sha }}
          title: "release(canary): ${{ github.sha }} → GCP ring"
          labels: release,ring-canary
          commit-message: "release(canary): ${{ github.sha }}"
```
When only one service changed, the matrix still rebuilds all three (simple and deterministic); to skip unchanged services, add a `paths-filter` job — pinned by SHA.

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
