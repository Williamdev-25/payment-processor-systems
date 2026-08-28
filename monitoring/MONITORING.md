# Monitoring Strategy — txn-gateway

## Why this folder exists on its own

Observability isn't a checkbox item bolted onto a deployment — it's the
mechanism that makes every other SRE practice in this project (SLOs,
alerting, the runbook, auto-remediation) actually possible. Everything
here answers one of three questions: **what do we watch, why do we watch
it, and who is it for.**

## The stack

`kube-prometheus-stack` (Prometheus + Grafana + Alertmanager +
node-exporter + kube-state-metrics), deployed via the Terraform module in
`monitoring/terraform/` — see that module's comments for the mechanics.
This section is about the *design choices*, not the deployment mechanics.

## Two dashboards, two different audiences — and why that split matters

A single dashboard trying to serve both an on-call engineer mid-incident
and a stakeholder checking in on overall health usually serves neither
well. So there are two, deliberately:

### `dashboards/golden-signals-dashboard.json` — for whoever is on call

Built around Google's four golden signals — the widely-used minimum set
of signals that, together, describe the health of almost any service:

| Signal | What it answers | Panel |
|---|---|---|
| **Latency** | How long are requests taking? | p50/p95/p99, with a red line at the 300ms SLO target |
| **Traffic** | How much load is the service under? | Requests/sec |
| **Errors** | What fraction of requests are failing? | Failure %, with threshold lines matching the actual alert thresholds |
| **Saturation** | How close to its resource limits is the service? | CPU/memory vs. the limits set in `k8s/deployment.yaml` |

Plus a sixth panel (pod restarts) that isn't one of the four "classic"
signals but is directly what `automation/remediate.py` and the
`TxnGatewayPodCrashLooping` alert both watch — included so an on-call
engineer can visually confirm what the automation already did, instead of
only trusting a log line.

**Every threshold drawn on this dashboard matches an actual number in
`monitoring/alerts/prometheusrule.yaml` and `docs/SLO.md`.** That's
deliberate — a dashboard whose visual thresholds disagree with what
actually pages someone is actively confusing during an incident, not
helpful.

### `dashboards/business-metrics-dashboard.json` — for everyone else

A different question entirely: not "is something broken right now" but
"how healthy is this service in terms that matter to the business."
Panels here are on a 24-hour window, not a 5-minute incident window —
longer time horizon, because the audience for this dashboard is checking
in periodically, not staring at it during an active page.

- **Settled / Failed transactions per minute** — throughput and impact, in
  units a non-engineer immediately understands, versus a raw HTTP status
  code breakdown.
- **30-day error budget remaining (gauge)** — a direct implementation of
  the error-budget math from `docs/SLO.md`. This is the number that's
  meant to drive a real conversation ("we've burned 70% of this month's
  error budget, we should prioritize reliability work over new features")
  rather than a vague, undocumented sense that "things feel a bit rocky."
- **Settlement volume + p95 latency trend (24h)** — spotting whether a
  problem correlates with a genuine traffic spike (capacity) or happened
  during otherwise-normal volume (a real regression).
- **A deliberately honest placeholder panel** on translating failures into
  an actual dollar-impact figure. This demo app has no real transaction
  value data, so the panel explains *why* it doesn't fabricate a number
  instead of inventing one — a real production version of this dashboard
  would multiply failure volume by an actual, sourced average transaction
  value, not a guess.

## How the dashboards actually get into Grafana

Not manually. `monitoring/terraform/main.tf` creates each dashboard's JSON
as a `kubernetes_config_map`, labeled `grafana_dashboard: "1"`. Grafana's
built-in sidecar container (enabled via the Helm chart's
`sidecar.dashboards.enabled` value) watches for ConfigMaps with that
label across the cluster and loads them automatically. This means the
dashboards are version-controlled, code-reviewed, and deployed the same
way as everything else in this repo — not click-ops that quietly drifts
from what's actually committed.

## The full loop, one more time

```
SLO defined (docs/SLO.md)
        ↓
Alert thresholds derived from it (monitoring/alerts/prometheusrule.yaml)
        ↓
Dashboard panels visualize the same thresholds (monitoring/dashboards/)
        ↓
Alert fires → routed by severity (Alertmanager) → runbook gives a specific next step (docs/runbook.md)
        ↓
Some failures get auto-remediated (automation/remediate.py)
        ↓
Dashboards show whether the remediation actually worked
```

Nothing in this chain is disconnected from anything else — that
end-to-end consistency, more than any individual tool choice, is the
actual point of this monitoring setup.

## Logs — the pillar metrics alone can't cover

Metrics answer **what** is wrong ("error rate is at 18%"). They can't
answer **why** — the actual downstream timeout message, a stack trace, a
malformed request payload. That's what logs are for, and it's why this
setup includes **Loki + Promtail** (`monitoring/terraform/main.tf`), not
just Prometheus:

- **Promtail** runs as a DaemonSet on every node, tails each container's
  stdout, attaches labels (pod, namespace, container), and ships the
  stream to Loki.
- **Loki** stores logs cheaply by indexing only those labels — not the
  full text of every log line the way Elasticsearch does — which keeps
  it simple and inexpensive to run for a project this size.
- **`txn-gateway` emits structured JSON logs** (see `app/txn-gateway/app.py`)
  specifically so LogQL queries can filter on real fields (`status`,
  `txn_id`) instead of fragile text matching.
- **Loki is registered as a Grafana datasource automatically**, the same
  ConfigMap-plus-sidecar pattern used for dashboards — no manual
  click-ops "add datasource" step.
- The golden-signals dashboard's final panel queries Loki directly
  (`{app="txn-gateway"} |= "error"`), so an on-call engineer sees the
  metric spike and the actual error messages behind it on one screen,
  without a separate `kubectl logs` detour mid-incident.

This is deliberately the simplest viable version (single-binary Loki,
local disk storage) — appropriate for a dev environment. A production
version would move Loki to S3-backed storage and multi-tenant mode for
real horizontal scale.

## Recording rules — why the alerts and dashboards use the same numbers

`monitoring/alerts/recording-rules.yaml` pre-computes the handful of
PromQL expressions used repeatedly across this project — error ratios,
p95/p99 latency — and saves each as its own lightweight metric (e.g.
`job:txn_error_rate:ratio5m`). Two real reasons this exists, not just
"because it's best practice":

1. **Speed** — a dashboard panel querying a pre-computed number loads
   instantly; re-running `histogram_quantile()` over raw high-resolution
   data on every single panel refresh is real, avoidable Prometheus load.
2. **Consistency** — `TxnGatewayFastBurnErrorRate` in
   `prometheusrule.yaml` and the error-rate panel in
   `golden-signals-dashboard.json` both reference the *same* recording
   rule. Two independently hand-written queries computing "the same
   thing" will eventually drift apart as one gets tweaked and the other
   doesn't — a shared recording rule makes that drift structurally
   impossible instead of relying on someone remembering to update both.

## Alert routing — what actually happens when an alert fires

Deploying Alertmanager isn't the same as having alert routing — without
configuration, alerts fire into a void nobody's watching. This project
configures real routing in `monitoring/terraform/main.tf`, driven
entirely by the `severity` label every alert already carries:

- **`severity: page`** → routed to a dedicated paging channel, grouped
  and re-notified every 15 minutes until resolved.
- **`severity: ticket`** → routed to a separate, lower-urgency channel,
  re-notified every 4 hours — frequent enough to not be forgotten, rare
  enough to not be noise.

Both currently route to Slack (via `var.slack_webhook_url`, a `sensitive`
variable — never hardcoded, overridden by a real CI secret). **A real
production setup would additionally wire the `page` route to PagerDuty
or Opsgenie** — Slack alone doesn't wake anyone up at 3am the way an
actual page does; it's flagged here explicitly rather than left as a
silent gap, since "we have Alertmanager" and "we have a working on-call
process" are not the same claim.
