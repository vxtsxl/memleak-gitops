#!/usr/bin/env python3
"""Generates monitoring/dashboards/memleak-sre-dashboard.json"""
import json
import pathlib

PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
_id = 0


def panel(title, kind, x, y, w, h, targets, ds=PROM, unit=None, extra=None):
    global _id
    _id += 1
    p = {
        "id": _id, "title": title, "type": kind, "datasource": ds,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [
            {"refId": chr(65 + i), "datasource": ds, **t} for i, t in enumerate(targets)
        ],
        "fieldConfig": {"defaults": {"unit": unit} if unit else {}, "overrides": []},
        "options": {},
    }
    if extra:
        p.update(extra)
    return p


def row(title, y):
    global _id
    _id += 1
    return {"id": _id, "type": "row", "title": title, "collapsed": False,
            "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}}


def q(expr, legend):
    return {"expr": expr, "legendFormat": legend}


NS = 'namespace="memleak"'
CTR = 'container!="",container!="POD"'
panels = [
    row("Application health", 0),
    panel("Ready pods", "stat", 0, 1, 4, 4,
          [q(f'sum(kube_pod_status_ready{{{NS},condition="true"}})', "ready")]),
    panel("Unready pods", "stat", 4, 1, 4, 4,
          [q(f'sum(kube_pod_status_ready{{{NS},condition="false"}}) or vector(0)', "unready")],
          extra={"fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [
              {"color": "green", "value": None}, {"color": "red", "value": 1}]}}, "overrides": []}}),
    panel("OOMKilled containers (last termination)", "stat", 8, 1, 4, 4,
          [q(f'sum(kube_pod_container_status_last_terminated_reason{{{NS},reason="OOMKilled"}}) or vector(0)', "oom")],
          extra={"fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [
              {"color": "green", "value": None}, {"color": "red", "value": 1}]}}, "overrides": []}}),
    panel("Container restarts (1h)", "timeseries", 12, 1, 12, 4,
          [q(f'increase(kube_pod_container_status_restarts_total{{{NS},container="app"}}[1h])', "{{pod}}")]),

    row("Pod metrics (namespace memleak)", 5),
    panel("Memory working set per pod vs 400Mi limit", "timeseries", 0, 6, 12, 8,
          [q(f'sum by (pod) (container_memory_working_set_bytes{{{NS},{CTR}}})', "{{pod}}"),
           q(f'max(kube_pod_container_resource_limits{{{NS},resource="memory",container="app"}})', "limit")],
          unit="bytes"),
    panel("CPU usage per pod", "timeseries", 12, 6, 12, 8,
          [q(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{NS},{CTR}}}[2m]))', "{{pod}}")],
          unit="cores"),

    row("Node metrics", 14),
    panel("Node CPU usage %", "timeseries", 0, 15, 8, 7,
          [q('100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100', "{{instance}}")],
          unit="percent"),
    panel("Node memory usage %", "timeseries", 8, 15, 8, 7,
          [q('(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100', "{{instance}}")],
          unit="percent"),
    panel("Node disk usage %", "timeseries", 16, 15, 8, 7,
          [q('100 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"} '
             '/ node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs"} * 100)', "{{instance}} {{mountpoint}}")],
          unit="percent"),

    row("Cluster metrics", 22),
    panel("CPU usage by namespace", "timeseries", 0, 23, 12, 8,
          [q(f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{{CTR}}}[2m]))', "{{namespace}}")],
          unit="cores"),
    panel("Memory usage by namespace", "timeseries", 12, 23, 12, 8,
          [q(f'sum by (namespace) (container_memory_working_set_bytes{{{CTR}}})', "{{namespace}}")],
          unit="bytes"),

    row("Logs (Loki)", 31),
    panel("Application logs", "logs", 0, 32, 24, 10,
          [{"expr": '{namespace="memleak", container="app"}', "queryType": "range"}],
          ds=LOKI, extra={"options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending"}}),
    panel("Log lines per pod", "timeseries", 0, 42, 24, 6,
          [{"expr": 'sum by (pod) (count_over_time({namespace="memleak", container="app"}[1m]))',
            "legendFormat": "{{pod}}"}], ds=LOKI),
]

dash = {
    "uid": "memleak-sre", "title": "Memleak SRE Overview", "tags": ["memleak", "sre"],
    "timezone": "browser", "schemaVersion": 39, "version": 1, "refresh": "10s",
    "time": {"from": "now-30m", "to": "now"}, "panels": panels,
}
out = pathlib.Path(__file__).resolve().parent.parent / "monitoring/dashboards/memleak-sre-dashboard.json"
out.write_text(json.dumps(dash, indent=2))
print("wrote", out)
