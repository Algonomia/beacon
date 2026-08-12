# Beacon

A comprehensive, production-ready observability stack for Kubernetes.

## Components

- **Prometheus** - Metrics collection, storage, and alerting
- **Loki** - Log aggregation and querying
- **Tempo** - Distributed tracing backend
- **Grafana Alloy** - Unified telemetry pipeline (OTLP + Faro RUM)
- **Promtail** - Log shipper (DaemonSet)
- **Blackbox Exporter** - HTTP/TCP/ICMP probing
- **Grafana** - Visualization, dashboards, and alerting UI

## Installation

The chart is published as a Helm repository:

```bash
helm repo add beacon https://algonomia.github.io/beacon
helm repo update
helm install observability beacon/beacon --namespace observability --create-namespace
```

### Prerequisites

- Kubernetes 1.20+
- Helm 3.8+
- Storage class configured for PVCs (or use `storageClassName` in values)

### Install

```bash
# Install with default values
helm install observability . \
  --namespace observability \
  --create-namespace

# Install with custom values
helm install observability . \
  --namespace observability \
  --create-namespace \
  --values custom-values.yaml

# Dry-run to see generated manifests
helm install observability . \
  --namespace observability \
  --dry-run --debug
```

### Upgrade

```bash
helm upgrade observability . \
  --namespace observability \
  --values custom-values.yaml
```

### Uninstall

```bash
helm uninstall observability --namespace observability

# Optionally delete PVCs (this deletes all data!)
kubectl delete pvc -n observability -l app.kubernetes.io/instance=observability
```

## Configuration

See `values.yaml` for all configuration options.

### Key Configuration

```yaml
global:
  namespace: observability
  domain: example.com
  basePath: /monitoring

prometheus:
  enabled: true
  storage:
    size: 5Gi
  retention: 15d

grafana:
  enabled: true
  admin:
    user: admin
    password: ""
  ingress:
    enabled: true
    host: example.com
    path: /monitoring/grafana
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    tls:
      secretName: grafana-tls
```

### Minimal Installation

To install only specific components:

```yaml
# minimal-values.yaml
prometheus:
  enabled: true
loki:
  enabled: true
grafana:
  enabled: true
tempo:
  enabled: false
alloy:
  enabled: false
promtail:
  enabled: false
blackboxExporter:
  enabled: false
```

```bash
helm install observability . \
  --values minimal-values.yaml \
  --namespace observability
```

## Security defaults

This chart optimises for a private cluster network, not a hostile one. Before exposing any component beyond the cluster, review:

- **Grafana admin password** is generated on first install and stored in the `grafana-admin` Secret. Set `grafana.admin.password` to pin it. Upgrades keep the existing value rather than rotating it.
- **Loki runs with `auth_enabled: false`** — any client reaching the service can read and write logs.
- **Alloy's OTLP and Faro receivers allow all CORS origins** (`["*"]`), so any page can post telemetry if the receiver is reachable.
- **The kubelet scrape job skips TLS verification** (`containerMonitoring.insecureSkipVerify`,
  default `true`): kubelet serving certificates are usually self-signed and absent from the
  cluster CA bundle. Set it to `false` where the kubelet cert is signed by a CA Prometheus trusts.
- Nothing in the chart provisions NetworkPolicies.

### Grafana sign-in via the application's session (`grafana.authProxy`)

Off by default. A shim answers nginx's `auth_request` by forwarding the caller's cookie to
`authProxy.validateUrl` and returning that username in `X-WEBAUTH-USER`, which Grafana trusts.

⚠️ Grafana trusts that header from anything reaching its Service — the protection is entirely in
front of Grafana. Two combinations are refused at render time:

- empty `validateUrl` — the shim has nothing to resolve against.
- `grafana.ingress.enabled: false` — the `auth_request` annotations live on that Ingress, so
  nothing runs the subrequest and any pod can sign in as any user.

`authProxy.whitelist` restricts who may set the header, and only means anything on a controller
that enforces `auth-url`.

## Discovery mode (recommended for shared clusters)

By default beacon *enumerates*: every consumer ConfigMap is listed in beacon's values, so adding an
application instance means upgrading the beacon release. With `discovery.enabled: true` beacon
*discovers* instead, and one beacon per cluster serves every namespace:

```yaml
discovery:
  enabled: true
  namespaces: []          # empty = all namespaces
  podLabels:              # pod label -> series/stream label
    env: env
    product: product
```

A consuming application then owns its own telemetry, entirely within its own namespace:

| what | how |
|---|---|
| **metrics** | annotate the pod `prometheus.io/scrape: "true"` (and `prometheus.io/port`) |
| **logs** | nothing — the Alloy DaemonSet tails every pod it discovers |
| **env / product labels** | set them as **pod labels**; `discovery.podLabels` maps them onto metrics and log streams |
| **dashboards** | a ConfigMap labelled `grafana_dashboard: "1"`, in any namespace |
| **Grafana alerts** | a ConfigMap labelled `grafana_alerting: "1"` |
| **Prometheus rules** | a ConfigMap labelled `prometheus_rules: "1"` (Prometheus is reloaded automatically) |

Nothing above requires a change to the beacon release, so per-instance pipelines can deploy
independently of whoever owns the cluster's observability stack. Two instances on one cluster
(`prod` and `preprod`) are separated by their `env` pod label, which reaches both metrics and logs.

Label keys are configurable via `grafana.sidecar.dashboardLabel`, `grafana.sidecar.alertingLabel`
and `prometheus.sidecar.rulesLabel`.

⚠️ `discovery.containerLabel` defaults to `false` and should stay there: it scrapes one target per
container instead of per pod, which on a 7-container Postgres pod was a 7× series multiplier that
OOM-killed Prometheus.

## Infrastructure scrape jobs

All off by default, and none enabled implicitly by `discovery.enabled`.

| values key | job | answers |
|---|---|---|
| `nodeExporter.enabled` | `node-exporter` | how loaded is the **host** — node CPU, RAM, disk, network |
| `kubeStateMetrics.enabled` | `kube-state-metrics` | what Kubernetes **declares** — pod phase, restarts, replicas, resource requests/limits |
| `containerMonitoring.enabled` | `kubelet` | what a **container actually uses** — per-container CPU and working-set memory |
| `postgresMonitoring.enabled` | `postgres` | Postgres exporter pods, one target per pod |
| `ingressMonitoring.enabled` | `nginx-ingress` | ingress-nginx controller metrics |
| `storageMonitoring.enabled` | `lukscryptwalker-csi` | the storage CSI's own metrics |

The first three do not overlap: the host is node-exporter, the *limit* is kube-state-metrics, and
actual usage is `containerMonitoring`. Without it `container_cpu_usage_seconds_total` and
`container_memory_working_set_bytes` do not exist and panels built on them render empty.

```yaml
containerMonitoring:
  enabled: true
  metricsPath: /metrics/resource   # or /metrics/cadvisor for the full set
```

`/metrics/cadvisor` adds per-filesystem, per-interface and CFS-throttling detail at a much higher
series count — pair it with `containerMonitoring.metricRelabelConfigs`.

`ingressMonitoring` and `storageMonitoring` point at a fixed `target` address; enabling either
where that Service does not exist just adds a permanently `down` target.

Both pod-discovering jobs drop pods in phase `Failed` or `Succeeded`, which can never answer a
scrape.

## Log collection: Alloy vs promtail

With `discovery.enabled`, an **Alloy DaemonSet** (`alloy.logs.enabled`, default on) discovers pods
cluster-wide and tails their container logs, attaching `namespace`, `pod`, `container`, `app` and
whatever you map in `discovery.podLabels`. Nothing has to be listed in beacon's values, so a new
application instance needs no change to the beacon release.

`promtail` remains for installs that still enumerate `promtailTargets`, and renders only when that
list is non-empty — so the two never ship the same logs twice. Note that **promtail reached
end-of-life in March 2026**; new installs should use discovery.

## Consumer Integration

Beacon is a pure infrastructure chart. Consumer projects (applications that use beacon for monitoring) provide their own dashboards, alerts, and scrape targets via ConfigMaps. Grafana mounts these ConfigMaps using **projected volumes** driven by the `dashboardConfigMaps` and `alertingConfigMaps` values.

There are two supported consumer models:

### Model A: Standalone ConfigMaps (recommended for most projects)

Create ConfigMaps in your project's kubernetes manifests containing Grafana dashboard JSON and alert rules. Apply them to the same namespace as beacon before deploying.

**Dashboard ConfigMap:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-myproject
  namespace: <namespace>
data:
  myproject-monitoring.json: |
    { "title": "My Project", "uid": "myproject", "panels": [ ... ] }
```

**Alert rules ConfigMap:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-alerting-myproject
  namespace: <namespace>
data:
  myproject-alertrules.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: My Alerts
        folder: My Project
        rules: [ ... ]
```

Then reference them in beacon's values so Grafana mounts them via projected volumes:

```yaml
grafana:
  dashboardConfigMaps:
    - grafana-dashboard-myproject
  alertingConfigMaps:
    - grafana-alerting-myproject
```

**Prometheus rule ConfigMaps** work the same way — list them under `prometheus.rulesConfigMaps` and they are mounted into `/etc/prometheus/alerts`, where `rule_files: '*.yml'` picks them up:

```yaml
prometheus:
  rulesConfigMaps:
    - prometheus-alerts-myproject
```

Every consumer-supplied ConfigMap is mounted as `optional`, so a name typo or a ConfigMap applied to the wrong namespace leaves the panels or rules missing rather than wedging the pod in `ContainerCreating`.

Chart-owned config changes (scrape targets, promtail targets, retention, ports) roll the affected pod automatically via a `checksum/config` annotation. Consumer ConfigMaps live outside the chart, so beacon cannot checksum them: after editing one, restart the pod yourself — or, for Prometheus rules, `POST /-/reload` (the chart runs with `--web.enable-lifecycle`). Grafana picks up dashboard and alerting file changes on its own provisioning interval.

Data keys must be unique across the listed ConfigMaps — a projected volume cannot merge two sources that expose the same key. The older `prometheus.alerts: true` gate still works and is equivalent to `rulesConfigMaps: ["prometheus-alerts"]`, but it allows only one consumer per namespace.

### Model B: Subchart wrapper (for projects needing helm templating)

If your dashboards need helm template rendering (e.g., parameterized job names), create a wrapper chart with beacon as a dependency:

Vendor beacon inside your repo — a git submodule is the usual way — and point the dependency at that path:

```yaml
# my-observability/Chart.yaml
apiVersion: v2
name: my-observability
version: 1.0.0
dependencies:
  - name: beacon
    version: "2.2.0"
    repository: "file://./beacon"    # a path INSIDE your repo
```

```bash
git submodule add https://github.com/Algonomia/beacon.git my-observability/beacon
helm dependency update my-observability
```

A `file://` path that climbs out of the consumer repo (`file://../../../beacon`) resolves only on a machine where both repos happen to sit side by side. Whether that breaks CI depends on whether your pipeline packages the chart at all — many do not, in which case the failure only hits whoever deploys by hand.

Place consumer ConfigMap templates in `my-observability/templates/`. Nest beacon values under the `beacon:` key in your values.yaml.

### Adding Scrape Targets

Use `extraScrapeConfigs` in values to add Prometheus scrape targets:

```yaml
extraScrapeConfigs: |
  - job_name: 'my-exporter'
    static_configs:
      - targets: ["my-exporter:9187"]
```

## Architecture

```
┌─────────────┐
│  Frontend   │──(RUM)─────┐
└─────────────┘            │
                           ▼
┌─────────────┐      ┌──────────┐
│  Backend    │─OTLP─▶│  Alloy   │
└─────────────┘      └──────────┘
                           │
      ┌────────────────────┼────────────────────┐
      │                    │                    │
      ▼                    ▼                    ▼
┌──────────┐         ┌──────────┐       ┌──────────┐
│   Loki   │◀─logs───│ Promtail │       │  Tempo   │
│  (Logs)  │         │(DaemonSet│       │ (Traces) │
└──────────┘         └──────────┘       └──────────┘
      │                                        │
      └──────────┐         ┌──────────────────┘
                 ▼         ▼
           ┌─────────────────────┐
           │   Grafana           │
           │  (Visualization)    │
           └─────────────────────┘
                     ▲
                     │
               ┌──────────┐
               │Prometheus│
               │(Metrics) │
               └──────────┘
```

## Accessing Grafana

After installation, Grafana will be available at:
- **URL**: https://{{ domain }}{{ basePath }}/grafana
- **Username**: admin (configurable)
- **Password**: generated on first install — `kubectl get secret -n <namespace> grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d`

## Monitoring Targets

The stack automatically monitors:
- All deployed components (self-monitoring)
- Application backend (/ping health endpoint)
- Custom targets (configure in `values.yaml`)

## Data Retention

Default retention periods:
- **Prometheus**: 15 days
- **Loki**: 7 days (168h)
- **Tempo**: Based on storage capacity

Configure in `values.yaml`:

```yaml
prometheus:
  retention: 30d

loki:
  retention: 336h  # 14 days
```

## Storage

Each persistent component requires storage:
- Prometheus: 5Gi default
- Loki: 5Gi default
- Tempo: 5Gi default
- Grafana: 1Gi default

Total: ~16Gi minimum

## Troubleshooting

### Check deployment status

```bash
helm status observability -n observability
kubectl get all -n observability -l app.kubernetes.io/instance=observability
```

### View logs

```bash
# Grafana
kubectl logs -n observability -l app=grafana

# Prometheus
kubectl logs -n observability -l app=prometheus

# Loki
kubectl logs -n observability -l app=loki
```

### Common issues

**Grafana won't start**: Check if storage PVC is bound
```bash
kubectl get pvc -n observability
```

**No metrics in Prometheus**: Check Alloy is forwarding metrics
```bash
kubectl logs -n observability -l app=alloy
```

**Ingress 404**: Verify ingress controller and annotations

## Development

To modify the chart:

1. Edit `values.yaml` or template files
2. Lint the chart: `helm lint .`
3. Test with dry-run: `helm install test . --dry-run --debug`
4. Install: `helm install test . -n test-namespace`

## License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE.md).
