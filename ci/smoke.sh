#!/usr/bin/env bash
set -euo pipefail
NS=observability
pf() { kubectl -n "$NS" port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 & }
pf prometheus 19090 9090; pf loki 13100 3100; pf tempo 13200 3200; pf alloy 14318 4318; pf grafana 13000 3000
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
sleep 3

retry() { local what="$1"; shift; for _ in $(seq 1 36); do if "$@" >/dev/null 2>&1; then echo "ok   $what"; return 0; fi; sleep 5; done; echo "FAIL $what"; return 1; }
prom() { curl -sfG --max-time 10 http://127.0.0.1:19090/api/v1/query --data-urlencode "query=$1" | jq -e '.data.result | length > 0'; }
graf() { curl -sf --max-time 10 -u admin:ci-password "http://127.0.0.1:13000/monitoring/grafana$1"; }

for job in prometheus alloy tempo loki blackbox-exporter kube-state-metrics node-exporter kubelet kubernetes-pods; do
  retry "target up: $job" prom "min(up{job=\"$job\"}) == 1"
done
retry "kube-state-metrics can list pods"            prom 'kube_pod_info{namespace="demo"}'
retry "kubelet resource metrics"                     prom 'container_memory_working_set_bytes{namespace="demo"}'
retry "scrape without Content-Type, pod label kept"  prom 'demo_up{env="ci"} == 1'
retry "discovered http probe"                        prom 'probe_success{job="health-demo"} == 1'
retry "discovered tcp probe"                         prom 'probe_success{job="health-demo-tcp"} == 1'
retry "rules ConfigMap from another namespace"       sh -c "curl -sf --max-time 10 http://127.0.0.1:19090/api/v1/rules | jq -e '[.data.groups[].name] | index(\"demo\")'"
retry "pod logs with a JSON field as label"          sh -c "curl -sfG --max-time 10 http://127.0.0.1:13100/loki/api/v1/query_range --data-urlencode 'query={namespace=\"demo\", level=\"info\", env=\"ci\"}' | jq -e '.data.result | length > 0'"

TRACE=5b8efff798038103d269b633813fc60c; NOW=$(date +%s%N)
curl -sf --max-time 10 -X POST http://127.0.0.1:14318/v1/traces -H 'Content-Type: application/json' -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"ci\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$TRACE\",\"spanId\":\"eee19b7ec3c1b174\",\"name\":\"ci\",\"kind\":1,\"startTimeUnixNano\":\"$NOW\",\"endTimeUnixNano\":\"$((NOW + 1000000))\"}]}]}]}" >/dev/null
retry "trace through alloy into tempo"               curl -sf --max-time 10 "http://127.0.0.1:13200/api/traces/$TRACE"

for ds in prometheus loki tempo; do
  retry "grafana datasource: $ds"                    sh -c "curl -sf --max-time 10 -u admin:ci-password http://127.0.0.1:13000/monitoring/grafana/api/datasources/uid/$ds/health | jq -e '.status == \"OK\"'"
done
retry "dashboard ConfigMap from another namespace"   graf /api/dashboards/uid/demo
retry "alerting ConfigMap from another namespace"    sh -c "curl -sf --max-time 10 -u admin:ci-password http://127.0.0.1:13000/monitoring/grafana/api/v1/provisioning/contact-points | jq -e '[.[].name] | index(\"demo\")'"

nodes=$(kubectl get nodes --no-headers | wc -l)
for ds in alloy-logs node-exporter; do
  retry "daemonset on all $nodes nodes: $ds" sh -c "[ \"\$(kubectl -n $NS get ds $ds -o jsonpath='{.status.numberReady}')\" = \"$nodes\" ]"
done

denied=0
for w in deploy/prometheus deploy/kube-state-metrics ds/alloy-logs; do
  logs=$(kubectl -n "$NS" logs "$w" --all-containers --tail=-1)
  [ -n "$logs" ] || { echo "FAIL no logs from $w"; exit 1; }
  n=$(grep -ciE 'forbidden|unauthorized' <<<"$logs" || true)
  echo "rbac refusals in $w: $n"; denied=$((denied + n))
done
[ "$denied" -eq 0 ] || { echo "FAIL rbac"; exit 1; }
for sa in prometheus grafana; do
  retry "serviceaccount $sa may list configmaps cluster-wide" kubectl auth can-i list configmaps --all-namespaces --as="system:serviceaccount:$NS:$sa"
done
echo "smoke passed"
