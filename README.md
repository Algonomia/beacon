# beacon

A Kubernetes observability stack packaged as a Helm chart: Prometheus, Loki, Tempo, Grafana,
Grafana Alloy, promtail, blackbox-exporter, and optional kube-state-metrics and node-exporter.

beacon ships **no dashboards and no alert rules**. Applications supply their own.

## Install

Requires Kubernetes 1.20+, Helm 3.8+, and a storage class for PVCs (or set `storageClassName`).

```bash
helm repo add beacon https://algonomia.github.io/beacon
helm repo update
helm install observability beacon/beacon \
  --namespace observability --create-namespace \
  --values my-values.yaml
```

Upgrade with `helm upgrade`, same flags. Uninstall with `helm uninstall observability -n
observability`; PVCs survive, delete them with `kubectl delete pvc -n observability -l
app.kubernetes.io/instance=observability` to drop the data.

Every setting is in [`values.yaml`](values.yaml).

⚠️ Resources land in `global.namespace`, **not** in `--namespace`.

## Instrument an application

Set `discovery.enabled: true` and applications instrument themselves, in their own namespace, with
no change to the beacon release:

```yaml
discovery:
  enabled: true
  namespaces: []          # empty = all namespaces
  podLabels:              # pod label -> metric/log label
    env: env
    product: product
```

| you want | in beacon | in your application |
|---|---|---|
| **metrics** | — | pod annotations `prometheus.io/scrape: "true"`, `prometheus.io/port`, optional `prometheus.io/path` |
| **logs** | — | nothing; the Alloy DaemonSet tails every discovered pod |
| **JSON log fields as labels** | `alloy.logs.json.labels` | pod annotation `beacon/logs: json` |
| **traces** | — | send OTLP to `alloy.<ns>.svc:4318` (HTTP) or `:4317` (gRPC) |
| **trace/log labels from resource attrs** | `alloy.otlp.resourceLabels` | set the matching OTEL resource attributes |
| **browser RUM** | `alloy.faro.labels`, optional `alloy.faro.apiKey` | POST Faro payloads to `alloy.<ns>.svc:12347/collect` |
| **`env` / `product` labels** | `discovery.podLabels` | set them as **pod labels** |
| **uptime probes** | — | Service annotations `prometheus.io/probe: "true"`, optional `prometheus.io/probe_module`, `prometheus.io/probe_path` (default `/health`), `prometheus.io/probe_name` |
| **dashboards** | — | ConfigMap labelled `grafana_dashboard: "1"`, any namespace |
| **Grafana alerts** | — | ConfigMap labelled `grafana_alerting: "1"` |
| **Prometheus rules** | — | ConfigMap labelled `prometheus_rules: "1"` |

Label keys are configurable: `grafana.sidecar.dashboardLabel`, `grafana.sidecar.alertingLabel`,
`prometheus.sidecar.rulesLabel`.

⚠️ `discovery.containerLabel` must stay `false`. It scrapes one target per container instead of per
pod — on a 7-container Postgres pod that is a 7× series multiplier.

### Browser RUM must be same-origin

A front-end with `connect-src 'self'` in its CSP cannot post to the Alloy Service directly. Proxy a
path on the front's own origin (e.g. `/monitoring/alloy/faro/`) to the `alloy` Service, or expose
`alloy.ingress`. The receiver answers `Access-Control-Allow-Origin: *`, so a *credentialed*
cross-origin request is refused by the browser regardless.

⚠️ An invalid Loki label name in `alloy.faro.labels` makes the whole Alloy Deployment crash-loop —
the chart fails the render instead.

### Without discovery

The chart otherwise enumerates: list consumer ConfigMaps in `grafana.dashboardConfigMaps`,
`grafana.alertingConfigMaps` and `prometheus.rulesConfigMaps`, and log targets in
`promtailTargets`. Adding an application then means upgrading the beacon release. promtail reached
end of life in March 2026; new installs should use discovery.

## Consumer ConfigMaps

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-myproject
  labels:
    grafana_dashboard: "1"        # with discovery; otherwise list the name in values
data:
  myproject.json: |
    { "title": "My Project", "uid": "myproject", "panels": [ ... ] }
```

Alert rules are the same with `grafana_alerting: "1"`, Prometheus rules with
`prometheus_rules: "1"` (Prometheus reloads automatically).

- Data keys must be unique across the ConfigMaps listed in one value — a projected volume cannot
  merge two sources exposing the same key.
- Consumer ConfigMaps are mounted `optional`, so a typo leaves panels empty rather than wedging the
  pod.
- beacon cannot checksum them, so after editing one restart the pod yourself, or `POST /-/reload`
  for Prometheus rules. Grafana reloads dashboards on its own interval.

⚠️ Changing a dashboard's `uid` in place does not work — Grafana keeps serving the old one. Delete
the ConfigMap, let it disappear, then apply the new one.

## Extra scrape targets

```yaml
extraScrapeConfigs: |
  - job_name: 'my-exporter'
    static_configs:
      - targets: ["my-exporter:9187"]
```

## Infrastructure scrape jobs

All off by default; none is enabled implicitly by `discovery.enabled`.

| values key | job | answers |
|---|---|---|
| `nodeExporter.enabled` | `node-exporter` | host CPU, RAM, disk, network |
| `kubeStateMetrics.enabled` | `kube-state-metrics` | what Kubernetes declares — pod phase, restarts, replicas, requests/limits |
| `containerMonitoring.enabled` | `kubelet` | what a container actually uses — per-container CPU and working-set memory |
| `postgresMonitoring.enabled` | `postgres` | Postgres exporter pods, one target per pod |
| `ingressMonitoring.enabled` | `nginx-ingress` | ingress-nginx controller metrics |
| `storageMonitoring.enabled` | `lukscryptwalker-csi` | the storage CSI's metrics |

The first three do not overlap: the host is node-exporter, the *limit* is kube-state-metrics, actual
usage is `containerMonitoring`. Without it `container_cpu_usage_seconds_total` and
`container_memory_working_set_bytes` do not exist.

```yaml
containerMonitoring:
  enabled: true
  metricsPath: /metrics/resource   # /metrics/cadvisor adds filesystem, network and CFS
                                   # throttling detail at ~26x the series count
```

`ingressMonitoring` and `storageMonitoring` point at a fixed `target` address; enabling either where
that Service does not exist adds a permanently `down` target.

## Log storage

`loki.retentionStreams` sets retention per stream selector; `loki.objectStore` moves chunks to an
S3-compatible bucket.

⚠️ Never flip `object_store` on an existing install. The index still resolves old chunk references
to the filesystem and the *entire* query fails. The chart adds a second schema period starting at
`loki.objectStore.from` (a future 00:00 UTC date) and keeps serving older chunks from the PVC, which
also still holds the WAL and compactor state.

## Security defaults

Tuned for a private cluster network. Before exposing anything beyond the cluster:

- **Grafana's admin password** is generated on first install into the `grafana-admin` Secret and
  preserved across upgrades. Pin it with `grafana.admin.password`. Under `helm template`, `--dry-run`
  or Argo CD the lookup returns empty and a new password is rendered each time.
- **Loki runs with `auth_enabled: false`** — anything reaching the Service can read and write logs.
- **Alloy's OTLP and Faro receivers allow all CORS origins.**
- **The kubelet scrape job skips TLS verification** (`containerMonitoring.insecureSkipVerify`,
  default `true`); kubelet certificates are usually self-signed. Set `false` where Prometheus trusts
  the signing CA.
- Nothing here provisions NetworkPolicies.

### Grafana sign-in via the application's session

`grafana.authProxy`, off by default. A shim answers nginx's `auth_request` by forwarding the caller's
cookie to `authProxy.validateUrl` and returning that username in `X-WEBAUTH-USER`. `validateUrl`
must accept the cookie and return HTTP 200 with a JSON body containing `authProxy.usernameField`.

Grafana trusts that header from anything reaching its Service, so all the protection is in front of
it. Three combinations are refused at render time: empty `validateUrl`, `grafana.ingress.enabled:
false`, and empty `whitelist`.

`whitelist` is matched against the immediate peer — the ingress controller's range, normally the
cluster pod CIDR. A wrong value denies everyone rather than admitting anyone, and it means nothing
on a controller that does not enforce `auth-url`.

## License

[GNU Affero General Public License v3.0](LICENSE.md).
