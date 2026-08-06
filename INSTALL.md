# Installation Guide - Observability Stack

## Quick Install

```bash
# From project root
helm install observability ./beacon \
  --namespace observability \
  --create-namespace
```

## Configuration Options

### Essential Configuration (values.yaml)

```yaml
# Namespace and domain
global:
  namespace: observability
  domain: example.com
  basePath: /monitoring
  appName: my-app

# Storage sizes (adjust based on your needs)
prometheus:
  storage:
    size: 5Gi  # Metrics storage
  resources:
    limits:
      cpu: 500m
      memory: 2Gi

loki:
  storage:
    size: 5Gi  # Logs storage
  retention: 168h  # 7 days
  resources:
    limits:
      cpu: 200m
      memory: 256Mi

tempo:
  storage:
    size: 5Gi  # Traces storage
  resources:
    limits:
      cpu: 200m
      memory: 512Mi

grafana:
  storage:
    size: 1Gi  # Dashboard storage
  admin:
    password: ""
  resources:
    limits:
      cpu: 250m
      memory: 256Mi

# Pods to collect logs from
promtailTargets:
  - namespace: default
    podPattern: "*backend*"
    labels:
      app: backend
  # Add more:
  # - namespace: production
  #   podPattern: "*api*"
  #   labels:
  #     app: api-service

# Health check endpoints
healthCheckTargets:
  - name: backend
    url: http://backend:80/health
    module: http_2xx
  # Add more:
  # - name: api
  #   url: http://api-service:80/healthz
  #   module: http_2xx
```

## Custom Values Install

1. Copy `values.yaml` to `custom-values.yaml`
2. Modify as needed
3. Install:

```bash
helm install observability ./beacon \
  --namespace observability \
  --create-namespace \
  --values custom-values.yaml
```

## Upgrade

```bash
helm upgrade observability ./beacon \
  --namespace observability \
  --values custom-values.yaml
```

## Verify Installation

```bash
# Check all pods are running
kubectl get pods -n observability -l app.kubernetes.io/instance=observability

# Check persistent volumes
kubectl get pvc -n observability

# Check services
kubectl get svc -n observability
```

Expected output: All pods should be Running

## Access Grafana

After installation, access Grafana at:
- **URL**: https://example.com/monitoring/grafana
- **Username**: admin
- **Password**: generated on first install — `kubectl get secret -n <namespace> grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d`

## Uninstall

```bash
# Remove Helm release
helm uninstall observability --namespace observability

# Optionally delete persistent data (WARNING: This deletes all metrics, logs, and traces!)
kubectl delete pvc -n observability -l app.kubernetes.io/instance=observability
```

## Troubleshooting

### Pods not starting

Check pod status:
```bash
kubectl describe pod -n observability <pod-name>
```

Common issues:
- **Insufficient storage**: Check PVC status
- **Insufficient CPU/memory**: Adjust resource limits in values.yaml
- **Image pull errors**: Check image repository and tags

### No data in Grafana

1. Check Alloy is receiving data:
```bash
kubectl logs -n observability -l app=alloy
```

2. Check Promtail is collecting logs:
```bash
kubectl logs -n observability -l app=promtail
```

3. Verify health checks are working:
```bash
kubectl logs -n observability -l app=blackbox-exporter
```

### Storage Issues

List PVCs:
```bash
kubectl get pvc -n observability
```

If a PVC is stuck in "Pending":
- Check if storage class is available: `kubectl get sc`
- Verify node has sufficient space
- Check PVC events: `kubectl describe pvc <pvc-name> -n observability`

## Resource Requirements

Minimum cluster requirements:
- **CPU**: ~1.5 cores total
- **Memory**: ~3.5 GB RAM total
- **Storage**: ~16 GB (4 PVCs)

Per component:
| Component | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
|-----------|-------------|-----------|----------------|--------------|---------|
| Prometheus | 100m | 500m | 512Mi | 2Gi | 5Gi |
| Loki | 50m | 200m | 128Mi | 256Mi | 5Gi |
| Tempo | 50m | 200m | 128Mi | 512Mi | 5Gi |
| Grafana | 50m | 250m | 128Mi | 256Mi | 1Gi |
| Alloy | 100m | 500m | 256Mi | 1Gi | - |
| Promtail | 50m | 200m | 64Mi | 128Mi | - |
| Blackbox | 10m | 50m | 32Mi | 64Mi | - |

## Configuration Examples

### Production Settings

```yaml
# production-values.yaml
prometheus:
  retention: 30d
  storage:
    size: 50Gi
    storageClassName: fast-ssd
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: 2000m
      memory: 8Gi

grafana:
  admin:
    password: "${GRAFANA_ADMIN_PASSWORD}"  # Use secret
  ingress:
    enabled: true
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
```

### Minimal Setup (Small cluster)

```yaml
# minimal-values.yaml
prometheus:
  storage:
    size: 5Gi
  resources:
    requests:
      cpu: 50m
      memory: 256Mi
    limits:
      cpu: 200m
      memory: 1Gi

loki:
  storage:
    size: 5Gi
  retention: 48h
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi

# Disable optional components
blackboxExporter:
  enabled: false
```

## Next Steps

1. Change Grafana admin password
2. Configure alert contact points in Grafana
3. Add custom dashboards
4. Configure additional health check targets
5. Add more Promtail targets for log collection
