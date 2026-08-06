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

### Prerequisites

- Kubernetes 1.20+
- Helm 3.8+
- Storage class configured for PVCs (or use `storageClassName` in values)

### Install

```bash
# Install with default values
helm install observability . \\
  --namespace observability \\
  --create-namespace

# Install with custom values
helm install observability . \\
  --namespace observability \\
  --create-namespace \\
  --values custom-values.yaml

# Dry-run to see generated manifests
helm install observability . \\
  --namespace observability \\
  --dry-run --debug
```

### Upgrade

```bash
helm upgrade observability . \\
  --namespace observability \\
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
    password: changeme  # CHANGE THIS!
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
helm install observability . \\
  --values minimal-values.yaml \\
  --namespace observability
```

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

Data keys must be unique across the listed ConfigMaps — a projected volume cannot merge two sources that expose the same key. The older `prometheus.alerts: true` gate still works and is equivalent to `rulesConfigMaps: ["prometheus-alerts"]`, but it allows only one consumer per namespace.

### Model B: Subchart wrapper (for projects needing helm templating)

If your dashboards need helm template rendering (e.g., parameterized job names), create a wrapper chart with beacon as a dependency:

```yaml
# my-observability/Chart.yaml
apiVersion: v2
name: my-observability
version: 1.0.0
dependencies:
  - name: beacon
    version: "1.0.0"
    repository: "file://../../beacon"
```

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
- **Password**: admin (CHANGE THIS!)

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
