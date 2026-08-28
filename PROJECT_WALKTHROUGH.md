# Project Walkthrough — fintech-sre-platform
### Written for a junior SRE engineer joining this project for the first time

This document explains every folder and every file in this repo — what it
does, why it exists, and how it connects to everything around it. Read it
top to bottom once, then use it as a reference.

---

## Part 0 — The big picture, before touching any file

This is a **standalone SRE/DevOps project**: one service (`txn-gateway`,
standing in for a fintech transaction gateway), deployed on Kubernetes
(EKS), with everything a real SRE role expects you to own end to end —
the network it runs on, the cluster it runs in, the pipeline that ships
it, how it's observed (both metrics *and* logs), what happens when it
breaks, and what fixes itself automatically.

The mental model to hold onto as you go: **every file exists to answer a
specific operational question.** Keep asking "why does this file exist"
as you read, not just "what does this file do."

**The layers, in the order data actually flows through them:**

```
Terraform (shared modules) → environments/dev (the real deployment)
                                        ↓
                              EKS cluster + txn-gateway
                                        ↓
                    Monitoring watches it (metrics AND logs)
                                        ↓
              Alerts fire → routed by severity → runbook / automation responds
```

---

## Part 1 — Root-level files

### `README.md`
The front door. States what this project is, the full folder layout, an
architecture diagram, *why* certain design decisions were made, how to
deploy it, and a "Known simplifications" section that's honest about what
a real production version would still need.

### `.gitignore`
Stops secrets and generated files from ever being committed: `*.tfvars`,
`*.tfstate`, Python's `__pycache__`.

---

## Part 2 — `.github/workflows/` — the CI/CD pipeline

### `ci-cd.yml`
One pipeline, eight jobs, each depending on the one before:

1. **`terraform-plan`** — `fmt`, `validate`, TFLint, then `terraform plan`
   against `environments/dev`. Posted as a PR comment for human review.
2. **`security-scan`** — Checkov and Trivy scan the **entire repo** (not
   just one folder — since Terraform now lives in three places:
   `terraform/modules`, `environments/dev`, and `monitoring/terraform`,
   scanning everything is simpler and safer than trying to enumerate each
   location separately).
3. **`test-app`** — installs Flask dependencies, smoke-tests every real
   endpoint, validates every Kubernetes YAML file (including everything
   in `monitoring/alerts/`) parses, checks the remediation script
   compiles.
4. **`security-scan-images`** — builds and scans both Docker images
   (`txn-gateway`, `remediation-bot`) in parallel.
5. **`manual-approval`** — opens a GitHub issue with the plan, waits for
   an approved person to comment `approved`. **Nothing past this point
   runs without a human explicitly signing off.**
6. **`deploy-infra`** — `terraform apply`, fresh against current state
   (not a stale saved plan — see the note on this in Part 3).
7. **`build-and-push`** — builds both images, tags with the Git commit
   SHA (never `:latest`), pushes to ECR.
8. **`deploy-app`** — applies every K8s manifest (app *and* all three
   alert files), sets the image, waits for rollout, **automatically rolls
   back via `kubectl rollout undo` if it fails or times out.**

### `.github/workflows/README.md`
One-time setup: the AWS OIDC role, and the repo secrets/variables that
must exist before the pipeline can run — including `TF_VAR_SLACK_WEBHOOK_URL`
now, alongside the Grafana password, for Alertmanager's routing.

---

## Part 3 — `terraform/` and `environments/` — infrastructure, split in two

**This is a structural decision worth understanding on its own.**
`terraform/` holds only **shared, reusable building blocks** — modules
that don't know or care which environment calls them. `environments/`
holds the **actual, deployable environments** — real values, real
resource calls, wired together from those shared modules. A second
environment (staging, prod) becomes a new sibling folder under
`environments/`, reusing the exact same modules at different sizing —
not a copy-paste of everything.

### `terraform/bootstrap/`
Solves a chicken-and-egg problem: Terraform needs somewhere to store its
*state*, and the plan is an S3 bucket — but you can't put state in a
bucket that doesn't exist yet. A small, **separate** config, run once
manually with its own local state, whose only job is creating that
bucket (versioning + encryption on) before anything else runs.

### `terraform/modules/vpc/`
The network, built from scratch. Worth understanding in `main.tf`:
- **Public subnets** host NAT gateways; **private subnets** host EKS
  nodes — nothing here is directly internet-reachable.
- **One NAT gateway per Availability Zone, not one shared gateway.** A
  genuine availability decision: a single shared NAT gateway is cheaper
  but becomes a single point of failure for *all* outbound traffic from
  every private subnet. For a project built around "high availability,"
  that trade-off would quietly undermine the whole premise.
- **Route tables are per-AZ too** — avoiding both a shared failure point
  and unnecessary cross-AZ data transfer costs.

### `terraform/modules/eks/`
The Kubernetes cluster. Four files:
- **`main.tf`** — `aws_eks_cluster` (control plane) and
  `aws_eks_node_group` (the actual EC2 instances running pods) as two
  separate resources, since AWS fully manages the former while you size
  and pay for the latter directly. Also enables control-plane audit
  logging to CloudWatch — off by default on EKS, one of the first things
  worth turning on beyond a toy cluster.
- **`iam.tf`** — roles for the cluster and the node group, plus an
  **OIDC provider** — the prerequisite for IRSA (letting one specific pod
  assume its own narrowly-scoped IAM role, instead of every pod on a node
  sharing the same broad permissions). Not used by an actual workload
  yet, but ready for it.
- **`variables.tf` / `outputs.tf`** — inputs (cluster version, subnets,
  node sizing) and what gets handed back to `environments/dev`.

### `environments/dev/`
Where the shared modules get called with real values — the actual,
deployable environment.

- **`backend.tf`** — state stored in the `bootstrap/`-created S3 bucket,
  `use_lockfile = true` for native S3 locking (so two people, or two CI
  runs, can't corrupt state writing simultaneously).
- **`provider.tf`** — `aws`, `tls` (EKS's OIDC setup), and `helm` +
  `kubernetes` (installing software *inside* the cluster directly from
  Terraform). Both auth via a short-lived `aws eks get-token` — no static
  kubeconfig or long-lived credential anywhere in the chain.
- **`main.tf`** — calls `module "vpc"`, then `module "eks"` (passing it
  the VPC's private subnets), then defines two ECR repos. Notice
  `image_tag_mutability = "IMMUTABLE"` — once a tag is pushed, it can
  never be silently overwritten, which matters in a regulated environment
  where "what code was actually running at time X" needs to be an
  unambiguous, guaranteed answer.
- **`monitoring.tf`** — deliberately thin: just calls `module "monitoring"`,
  sourced from `../../monitoring/terraform`. Passes through
  `enable_logging` and `slack_webhook_url` alongside the settings from
  before — the actual monitoring logic lives in its own folder entirely
  (Part 4).
- **`variables.tf` / `outputs.tf` / `terraform.tfvars.example`** —
  configurable inputs (now including `enable_logging` and
  `slack_webhook_url`), deploy outputs, and a safe local-values template.

**One more thing worth remembering about `deploy-infra` in the CI
pipeline:** it runs a *fresh* `terraform apply` against current state
every time, rather than reusing a plan saved earlier in the pipeline.
An hours-old saved plan applied after other steps have already changed
state is a real, common bug — Terraform refuses to apply a plan computed
against state that's since moved. Worth knowing this pattern by name if
it ever comes up: **"stale plan" error.**

---

## Part 4 — `monitoring/` — observability as its own first-class system

Separate from `environments/dev` on purpose: observability is the
mechanism that makes every other SRE practice in this repo (SLOs,
alerting, the runbook, auto-remediation) actually possible, not an
afterthought bolted onto a deployment.

### `monitoring/terraform/`
A **reusable module**, for the same reason `terraform/modules` exists —
a real second environment would want the identical monitoring setup at
different sizing, and a module makes that a one-line call.

**`main.tf` does four distinct jobs — walk through each:**

1. **Deploys `kube-prometheus-stack`** via the `helm` provider — bundles
   Prometheus (scrapes/stores metrics), Grafana (dashboards), Alertmanager
   (routes alerts), and node-exporter + kube-state-metrics (the agents
   exposing node/pod-level data, included automatically by this chart).
2. **Configures real Alertmanager routing** — this is new, and it matters:
   deploying Alertmanager isn't the same as having working alert routing.
   The config routes purely off the `severity` label every alert already
   carries: `severity: page` → a dedicated paging Slack channel,
   re-notified every 15 minutes until resolved; `severity: ticket` → a
   separate, lower-urgency channel, re-notified every 4 hours. Both go
   through `var.slack_webhook_url` — a `sensitive` variable, never
   hardcoded. **Honest gap, stated directly in the README:** this
   currently only reaches Slack — a real production setup would route
   `page` additionally to PagerDuty or Opsgenie, since a Slack message
   alone doesn't wake anyone up the way an actual page does.
3. **Deploys Loki + Promtail** — the piece that closes the biggest gap
   this project used to have. Metrics tell you *what* is wrong ("error
   rate spiked"); they can't tell you *why*. Logs can.
   - **Promtail** runs as a DaemonSet on every node, tails each
     container's stdout, attaches labels (pod/namespace/container), ships
     to Loki.
   - **Loki** stores logs cheaply by indexing only those labels — not the
     full text the way Elasticsearch does. Deployed here in
     **single-binary mode with local disk storage** — appropriate for a
     dev environment; production would move to S3-backed, multi-tenant
     mode.
   - Registered as a Grafana datasource automatically, via the exact same
     labeled-ConfigMap-plus-sidecar pattern as the dashboards (see next
     point) — no manual "add datasource" click-ops step.
4. **Provisions two dashboards as code** via `kubernetes_config_map`
   resources, each labeled `grafana_dashboard: "1"`. Grafana's sidecar
   (`sidecar.dashboards.enabled` in the Helm values) watches for
   ConfigMaps with that label and auto-loads them. **The dashboards are
   version-controlled and deployed the same way as everything else in
   this repo — nobody manually clicks "import dashboard."**

- **`variables.tf` / `outputs.tf`** — chart versions (all pinned
  explicitly — Prometheus, Loki, *and* Promtail — never `latest`),
  retention, the Grafana password, and the Slack webhook URL, both marked
  `sensitive`.

### `monitoring/dashboards/`
Two dashboards, real PromQL wired to `txn-gateway`'s actual metrics — not
placeholders. **Why two, not one:** a single dashboard trying to serve
both an engineer mid-incident and a stakeholder checking in on health
usually serves neither well.

- **`golden-signals-dashboard.json`** — for whoever's on call. The four
  golden signals (Google SRE's minimum set for describing any service's
  health): **Latency** (p50/p95/p99, red line at the 300ms SLO target),
  **Traffic** (requests/sec), **Errors** (failure %, threshold lines
  matching the *actual* alert thresholds — 1.5% and 14%), **Saturation**
  (CPU/memory vs. the limits in `k8s/deployment.yaml`). Plus a sixth
  panel (pod restarts) mirroring what the remediation bot watches, and —
  new — a **seventh panel: a live Loki logs query**
  (`{app="txn-gateway"} |= "error"`), so the metric spike and the actual
  error messages behind it sit on one screen. This directly matches what
  a standard Kubernetes monitoring curriculum calls "a unified dashboard
  with both metrics and logs."

  **Every threshold on this dashboard matches a real number in
  `monitoring/alerts/prometheusrule.yaml` and `docs/SLO.md`** — a
  dashboard whose visual thresholds disagree with what actually pages
  someone is actively confusing mid-incident, not helpful.

- **`business-metrics-dashboard.json`** — a different question: not "is
  something broken" but "how healthy is this in terms the business cares
  about." 24-hour windows, not 5-minute ones. Settled/failed transactions
  per minute, a **live gauge computed directly from the error-budget math
  in `docs/SLO.md`**, a volume + latency trend, and a text panel that
  **deliberately does not fabricate a dollar-impact figure** — explaining
  instead why a real version would need actual transaction-value data
  first, rather than inventing a number that looks impressive for five
  seconds and destroys the dashboard's credibility the moment someone
  asks where it came from.

### `monitoring/alerts/` — three files now, each with a distinct job

- **`prometheusrule.yaml`** — the SLO-derived application alerts. Four
  alerts, still the most important file in the project to understand
  deeply:
  1. **`TxnGatewayFastBurnErrorRate`** — error rate over 5 minutes exceeds
     14%, sustained 2+ minutes. `severity: page`. That 14% is the exact
     burn rate at which the entire 30-day error budget would be
     exhausted in under a day.
  2. **`TxnGatewaySlowBurnErrorRate`** — error rate over 1 *hour* exceeds
     1.5%, sustained 30+ minutes. `severity: ticket`. Catches a slow,
     sustained problem the fast-burn alert would never trip on.

     **Why two, not one threshold?** A single fixed number either pages
     too often on brief blips, or misses slow-burning real problems
     entirely. This two-speed pattern — multi-window, multi-burn-rate
     alerting — is the real industry-standard approach.
  3. **`TxnGatewayHighLatency`** — p95 latency over 300ms for 5+ minutes.
  4. **`TxnGatewayPodCrashLooping`** — a pod restarting more than 3 times
     in 15 minutes. Not SLO-derived like the others — a basic
     operational check that can catch the underlying mechanism faster
     than waiting for user-facing error rate to climb.

  **New detail:** the first three now reference `recording-rules.yaml`
  metrics (e.g. `job:txn_error_rate:ratio5m`) instead of raw queries —
  see below for why.

- **`recording-rules.yaml`** — new. Pre-computes the handful of PromQL
  expressions used repeatedly (error ratios, latency percentiles) and
  saves each as its own lightweight metric. Two real reasons this exists:
  1. **Speed** — a dashboard panel querying a pre-computed number loads
     instantly instead of re-running `histogram_quantile()` over raw data
     on every refresh.
  2. **Consistency** — the alert rule and the dashboard panel now
     reference the *same* recording rule, so they can't quietly drift
     apart the way two independently hand-written queries eventually do.

- **`infra-alerts.yaml`** — new. Everything the SLO-derived application
  alerts deliberately don't cover: the cluster/node layer underneath
  every workload. An app can look perfectly healthy on its own SLOs right
  up until the node it's running on runs out of disk. Covers: `NodeDown`,
  `NodeMemoryHighUsage`, `NodeDiskSpaceWarning`/`Critical` (80%/95%
  thresholds), `PersistentVolumeUsageWarning`/`Critical` (80%/95% — this
  matters here specifically because Prometheus's and Loki's own storage
  volumes are exactly the kind of thing that quietly fills up over time),
  and `DeploymentNotAvailable` (zero ready replicas — full outage, not
  degraded).

### `monitoring/MONITORING.md`
The strategy doc tying all of the above together — now covering metrics,
logs, recording rules, and alert routing as four connected pieces, not
just the original metrics-and-dashboards story. If you read one file to
understand *why* monitoring was built the way it was, this is the one.

---

## Part 5 — `app/txn-gateway/` — the service itself

### `app.py`
A small Flask service standing in for a fintech transaction gateway.
Business logic is intentionally minimal — the point is to be a realistic,
observable, occasionally-failing system to build the rest of the project
around.

- **`POST /transactions`** — ~5% of requests fail (`FAILURE_RATE`), ~3%
  are artificially slow (`SLOW_RATE`), both configurable via env vars.
- **`/healthz`** (liveness) — deliberately **not** affected by the random
  failure rate, only by a genuinely stuck state — conflating "one request
  failed" with "this process needs restarting" is a common real mistake.
- **`/readyz`** (readiness) — a genuinely separate check: "should traffic
  route here right now," not "is this process alive."
- **`/metrics`** — Prometheus counters/histograms via `prometheus_client`.
- **New: structured JSON logging.** Every settled or failed transaction
  now logs a real line — timestamp, level, message, `txn_id`, `status`,
  `duration_ms` — written to stdout as JSON via a custom `JsonFormatter`.
  This is what Promtail actually tails and ships to Loki. It's JSON
  specifically (not free-form text) so LogQL queries can filter on real
  fields instead of fragile string matching — the difference between
  `{app="txn-gateway"} | json | status="failed"` and hoping a substring
  match happens to catch what you're looking for.
- **`/admin/break` and `/admin/fix`** — test-only hooks to demo the whole
  alert → runbook → remediation loop live, on command.

### `requirements.txt` / `Dockerfile`
Flask, `prometheus-client`, `gunicorn` (never Flask's dev server for
actually running the app). Runs as a non-root user.

---

## Part 6 — `k8s/` — what runs on top of the cluster

Applied via `kubectl` in CI's `deploy-app` job, not via Terraform — a
deliberate split: `terraform/modules/eks` and `environments/dev` create
the *cluster itself*; infra changes are rare and get careful review.
App-level Kubernetes objects change far more often and need faster
iteration.

### `deployment.yaml`
- **Deployment** — 3 replicas, spread across AZs
  (`topologySpreadConstraints` — without this, "3 replicas" could still
  mean zero real protection if they land on one zone by chance),
  resource requests/limits, and the liveness/readiness probes from
  Part 5.
- **PodDisruptionBudget (`minAvailable: 2`)** — protects availability
  during *voluntary* disruptions (node drains, cluster upgrades) — easy
  to forget that replica count alone doesn't cover this.
- **HorizontalPodAutoscaler** — 3 to 10 replicas on 70% CPU.

### `service.yaml`
- **Service (`ClusterIP`)** — internal-only stable identity for the pods.
- **ServiceMonitor** — tells the Prometheus Operator to scrape
  `/metrics` every 15 seconds. Without it, Prometheus has no idea
  `txn-gateway` exists.

### `remediation-cronjob.yaml`
- **ServiceAccount + Role + RoleBinding** — `get`/`list`/`delete` on pods
  only, this namespace only. Not cluster-admin, no Secrets access. A
  concrete answer to "how do you scope an automation tool's blast
  radius."
- **CronJob**, not a long-running Deployment — the check is cheap and
  stateless, and this caps blast radius: a bug in the bot's own image
  means one failed job every 5 minutes, not an indefinitely crash-looping
  pod.

---

## Part 7 — `automation/` — the remediation bot

### `remediate.py`
1. **`load_k8s_config()`** — in-cluster config first, local kubeconfig as
   fallback for manual testing.
2. **`get_unhealthy_pods()`** — flags pods restarted more than 3 times.
   **Deliberately mirrors the exact logic of `TxnGatewayPodCrashLooping`**
   — the automation and the alerting look at the same signal.
3. **`in_cooldown()`** — won't re-remediate the same pod within 10
   minutes — the safety mechanism against a "restart → still broken →
   restart again" loop.
4. **`remediate_pod()`** — deletes the pod; the Deployment's ReplicaSet
   controller notices and creates a fresh replacement automatically.
5. **`--dry-run` defaults to `True`.** Only *logs* what it would do
   unless explicitly told `--no-dry-run` — an automation tool capable of
   destructive action should never default to "just do it."

Every action gets logged with a timestamp and reason — in a regulated
environment, "what changed, when, and why" isn't optional.

### `Dockerfile`
Non-root, packages the script for the CronJob.

---

## Part 8 — `docs/` — the reasoning behind the numbers

### `SLO.md`
- **SLI vs SLO** — SLI is what you measure; SLO is the target you commit
  to for it.
- **99.5%, not 99.9%+** — a deliberate, explained trade-off, not "more
  nines are always better." Explicit that a real trading platform's
  actual number would come from the business's real tolerance for
  settlement delay, not be picked by the SRE team alone.
- **Why latency gets equal weight with availability** — for a transaction
  gateway specifically, a slow-but-successful request can be as costly as
  a failed one (stale pricing, missed execution windows).
- **Error budget** — the policy (pause feature work if half the monthly
  budget burns in a week) is what turns an SLO from a dashboard number
  into something that actually changes engineering priorities. This is
  literally the number the business-metrics dashboard's gauge visualizes.

### `runbook.md`
One section per alert — **now covering both the application-level SLO
alerts and the new infrastructure-level alerts** (node down, disk space,
PV usage, deployment unavailable) — each linked directly from its
alert's annotation. The point isn't covering every conceivable scenario;
it's giving whoever's on call a fast, confident starting point instead of
a blank page.

---

## Summary — the whole thing in one pass

- **`terraform/` (shared modules) and `environments/dev` (the actual
  deployment) are deliberately split** — a second environment is a new
  sibling folder reusing the same modules, not a rewrite.
- **`terraform/modules/vpc`** has a real availability decision baked in
  (per-AZ NAT gateways). **`terraform/modules/eks`** builds the cluster
  plus the IAM/OIDC groundwork for future IRSA.
- **Monitoring is its own dedicated system** (`monitoring/`) covering
  **both pillars of observability that matter here**: metrics
  (Prometheus/Grafana) *and* logs (Loki/Promtail) — not metrics alone.
- **Alerting is layered, not arbitrary, and never duplicated.**
  SLO-derived application alerts (`prometheusrule.yaml`) sit alongside
  infrastructure alerts (`infra-alerts.yaml`); both use shared
  pre-computed values (`recording-rules.yaml`) so the alert and the
  dashboard panel showing it can never quietly disagree.
- **Alerts are actually routed by severity** — page vs. ticket, different
  channels, different re-notification cadence — with the Slack-only
  limitation stated honestly rather than hidden.
- **`txn-gateway`** is built to *not* be perfectly reliable on purpose,
  and now emits real structured logs, not just metrics — the mechanism
  that makes the whole system demonstrable, not just described.
- **`docs/runbook.md`** turns every alert — app-level and infra-level —
  into an immediate, concrete first action.
- **`automation/remediate.py`** closes the loop conservatively: dry-run
  default, rate-limited, fully logged, tightly scoped RBAC.
- **The CI/CD pipeline** ties all of it together end to end, with a human
  approval gate before infrastructure changes and automatic rollback if
  an app deploy goes wrong.

If you can explain *why* each of these pieces exists — not just what it
does — you can defend this project confidently in almost any SRE or
DevOps interview. The recurring question, answered concretely instead of
left implicit almost everywhere in this repo: **"what happens when this
breaks, and what did we build ahead of time to handle it?"**
