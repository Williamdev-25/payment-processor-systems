# fintech-sre-platform

A self-contained SRE/DevOps project: a fintech-style transaction gateway
service, deployed on EKS via Terraform, with a full CI/CD pipeline,
SLO-derived alerting, an incident runbook, and automated remediation for
one common failure mode.

Built to demonstrate ownership of the full stack a Site Reliability
Engineer is expected to reason about -- not just Kubernetes manifests in
isolation, but the infrastructure underneath them, the pipeline that
ships them, and the operational practices that keep them reliable.

## Repo layout

```
terraform/
  bootstrap/                 One-time setup: S3 bucket for remote Terraform state
  modules/
    vpc/                     2-AZ VPC: public + private subnets, per-AZ NAT gateways
    eks/                     EKS cluster + managed node group + IAM/OIDC (IRSA-ready)

environments/
  dev/                       The deployable dev environment -- wires the shared
                              modules together: VPC, EKS cluster, ECR repos.
                              Delegates monitoring to the monitoring/terraform
                              module. A second environment (staging/prod) would
                              live as a sibling folder here, reusing the same
                              modules and monitoring stack at different sizing.

monitoring/                  Observability as a first-class part of this platform,
                              not an inline afterthought -- see monitoring/MONITORING.md
  terraform/                 Reusable module: kube-prometheus-stack (metrics),
                              Loki + Promtail (logs), dashboard + datasource
                              provisioning, and Alertmanager routing -- all via
                              Terraform's helm provider, no manual click-ops
  dashboards/                golden-signals-dashboard.json (on-call view: latency,
                              traffic, errors, saturation, plus a live Loki logs
                              panel) + business-metrics-dashboard.json (settlement
                              volume, error budget, revenue-relevant view)
  alerts/                    prometheusrule.yaml (SLO-derived, multi-window
                              burn-rate app alerts), recording-rules.yaml
                              (pre-computed metrics shared by alerts + dashboards),
                              infra-alerts.yaml (node/disk/PV/deployment health)
  MONITORING.md               The observability strategy: metrics, logs, alert
                              routing, and why each piece exists

app/
  txn-gateway/                Flask service simulating a fintech transaction
                               gateway -- realistic, configurable failure/latency
                               rates, Prometheus-instrumented, structured JSON
                               logging, liveness/readiness split, non-root container

k8s/                          Deployment, PDB, HPA, Service, ServiceMonitor, and
                               the remediation bot's CronJob + least-privilege RBAC
                               (alerting/logging config lives in monitoring/ instead)

automation/
  remediate.py                 Auto-remediation tool for crash-looping pods --
                               dry-run by default, rate-limited, fully audit-logged

docs/
  SLO.md                      SLI/SLO definitions, error budget, and the
                               reasoning behind every number
  runbook.md                  Incident response, one section per alert (app-level
                               and infra-level), linked from each alert's annotations

.github/workflows/
  ci-cd.yml                   Full pipeline: plan -> security scan -> test ->
                               image scan -> manual approval -> apply infra ->
                               build & push -> deploy -> auto-rollback on failure
  terraform-destroy.yml        Manual-only workflow: deletes all Kubernetes
                               workloads first, then runs terraform destroy to
                               tear down EKS, VPC, monitoring stack, and ECR.
                               Requires manual approval before anything is deleted.
                               Triggered exclusively via the GitHub Actions UI,
                               never on push.
  README.md                   One-time CI/CD setup instructions
```

## Architecture

```
                     ┌──────────────────────┐
   POST /transactions│      txn-gateway       │ → simulated realistic
        (client) ───→│  (Flask, 3 replicas)   │    failure/latency
                     └──────────┬─────────────┘
                        │ /metrics        │ stdout logs (JSON)
                        ▼                 ▼
          ┌──────────────────┐  ┌─────────────────┐
          │ Prometheus Operator │  │  Promtail (DaemonSet)│
          │ (kube-prometheus-   │  │  → ships to Loki      │
          │  stack, via Helm)   │  └─────────────────┘
          └──────────┬──────────┘
                    │ evaluates (using recording-rules.yaml
                    │  for shared, pre-computed values)
                    ▼
          ┌───────────────────────┐
          │ PrometheusRule (app) +   │ → alerts derived from
          │ infra-alerts.yaml         │    docs/SLO.md + node/PV health
          └─────────┬─────────────┘
                    ▼
          ┌───────────────────────┐    ┌─────────────────────────┐
          │ Alertmanager (routes by  │    │  Grafana (2 dashboards +  │
          │ severity: page/ticket)   │    │  Loki logs panel, auto-   │
          └─────────┬─────────────┘    │  loaded via sidecar)       │
                    │                   └─────────────────────────┘
        ┌───────────┴────────────┐
        ▼                         ▼
  Paging channel           Ticket channel
  → docs/runbook.md         → docs/runbook.md
        │
        ▼
  remediate.py (CronJob, least-privilege RBAC)
  → auto-deletes crash-looping pods
```

One VPC, one EKS cluster, both provisioned by Terraform. Everything
inside the cluster (the app, the monitoring stack's workloads, the alert
rules, the remediation bot) is either Helm-installed by Terraform
(monitoring) or applied via `kubectl` through the CI pipeline (the app and
its supporting K8s objects) -- a deliberate split: infrastructure changes
are relatively rare and get a human-approval gate; app deploys are
frequent and need to be fast, with automatic rollback as the safety net
instead.

## Why this design

- **Logs, not just metrics.** Metrics tell you *what* broke (error rate
  spiked); they can't tell you *why*. Loki + Promtail are deployed
  alongside Prometheus specifically to close that gap, and `txn-gateway`
  emits structured JSON logs so they're actually queryable, not just
  greppable free text.
- **Recording rules back both the alerts and the dashboards with the same
  numbers.** `monitoring/alerts/recording-rules.yaml` pre-computes error
  ratios and latency percentiles once; `prometheusrule.yaml` and the
  golden-signals dashboard both reference the same computed metric, so
  they can't quietly drift apart the way two hand-written queries
  eventually do.
- **Alerts are actually routed, not just generated.** Alertmanager's
  config (`monitoring/terraform/main.tf`) routes by the `severity` label
  every alert already carries -- paging alerts to one channel with fast
  re-notification, tickets to another with a slower cadence. Flagged
  explicitly in "Known simplifications" below: this currently routes to
  Slack only, not a real paging system.
- **Environments live in their own top-level folder** (`environments/dev`),
  separate from the shared `terraform/modules`. A second environment is a
  new sibling folder reusing the same modules, not a copy-paste of
  everything.
- **Monitoring is a standalone, reusable Terraform module** (`monitoring/terraform`),
  not inline resources bolted onto the environment config -- a real
  second environment would want the identical setup at different sizing,
  and a module is what makes that a one-line call instead of copy-paste.
- **Two Grafana dashboards for two different audiences**, provisioned as
  code via Kubernetes ConfigMaps (not manually clicked into existence):
  a golden-signals view for whoever's on call, and a business-metrics
  view -- settlement volume, error-budget burn -- for anyone who needs to
  understand reliability in terms that matter to the business, not HTTP
  status codes. See `monitoring/MONITORING.md` for the full reasoning.
- **VPC has per-AZ NAT gateways, not one shared gateway.** A single NAT
  gateway is cheaper but becomes a single point of failure for all
  outbound traffic from every private subnet -- wrong trade-off for
  anything claiming "high availability."
- **ECR repos use `IMMUTABLE` tags.** Once an image tag is pushed, it
  can't be silently overwritten -- meaningful in a regulated environment
  where "what code was actually running at time X" needs to be a
  guaranteed, unambiguous answer.
- **Liveness and readiness are separate checks**, not the same endpoint
  reused. Conflating them is a common real-world mistake that causes pods
  to be killed for transient issues, or kept alive when genuinely stuck.
- **SLOs are written before the alert rules that enforce them.** Every
  threshold in `k8s/prometheusrule.yaml` is a direct, explainable
  derivation of a number in `docs/SLO.md` -- not a guessed value.
- **Multi-window burn-rate alerting** (fast page vs. slow ticket) avoids
  the two failure modes of naive alerting: paging on noise, or missing a
  slow-developing problem that never spikes high enough in a short window
  to trip a single fixed threshold.
- **The remediation bot defaults to dry-run, is rate-limited per pod, and
  runs with RBAC scoped to `get/list/delete` on pods only** -- an
  automation tool capable of destructive action should never default to
  "just do it," and its blast radius should be bounded even if it has a
  bug.
- **Every alert links to a specific runbook section.** The goal: someone
  paged at 3am gets an immediate, concrete next step, not a blank page.

## Secrets — current state vs. production

Grafana's admin password currently flows through a Terraform `-var` flag
sourced from a GitHub Actions secret -- fine for a demo. A real
production/fintech environment would instead use **IRSA + AWS Secrets
Manager** (or Vault via External Secrets Operator), so credentials are
pulled directly at runtime by a scoped per-pod IAM role, never passed
through CI variables or stored as a static Kubernetes Secret. The OIDC
provider `terraform/modules/eks` already creates is the prerequisite
piece for wiring this in.

## Running it

**One-time setup:**
```bash
cd terraform/bootstrap
terraform init && terraform apply
```
See `.github/workflows/README.md` for the CI/CD secrets/role setup.

**Deploy infrastructure (normal path):** open a PR -> plan gets posted as
a comment for review -> merge to `main` -> approve the manual-approval
gate -> CI applies it, builds/pushes images, deploys to EKS.

**Destroy all resources (when done):** GitHub Actions -> "Terraform Destroy"
-> Run workflow -> approve the issue that opens by commenting `approved`.
This deletes all Kubernetes workloads first, then runs `terraform destroy`.
Note: the S3 state bucket (`fintech-sre-platform-tfstate`) is not managed
by this Terraform project and must be deleted manually from the AWS console
if a fully clean account is needed.

**Manual/local path:**
```bash
cd environments/dev
terraform init
terraform apply

aws eks update-kubeconfig --name dev-eks --region us-east-1
kubectl apply -f ../../k8s/deployment.yaml
kubectl apply -f ../../k8s/service.yaml
kubectl apply -f ../../monitoring/alerts/prometheusrule.yaml
kubectl apply -f ../../monitoring/alerts/recording-rules.yaml
kubectl apply -f ../../monitoring/alerts/infra-alerts.yaml
kubectl apply -f ../../k8s/remediation-cronjob.yaml
```

**Demo the SLO -> alert -> remediation loop end-to-end:**
```bash
kubectl exec deploy/txn-gateway -- curl -X POST localhost:8080/admin/break
# watch: kubectl get prometheusrules -n monitoring
# watch: kubectl logs -l app=remediation-bot --tail=50 (after next CronJob run)
```

**Grafana access (both dashboards auto-load via the sidecar, no manual import):**
```bash
kubectl get svc -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# login: admin / <grafana_admin_password>
# Dashboards -> "txn-gateway — Golden Signals" and "txn-gateway — Business & Settlement Metrics"
```

## Known simplifications

This is a demo-scale project, not a production reference architecture:
- `txn-gateway`'s transaction logic is entirely simulated -- no real
  ledger, settlement, or persistence layer.
- No WAF, no API gateway/authentication layer in front of the service.
- Secrets flow through CI `-var` flags rather than IRSA + Secrets Manager
  (see "Secrets" section above for the intended production pattern).
- The EKS public API endpoint is scoped to a single admin CIDR; a stricter
  setup would go fully private-endpoint-only with a VPN/bastion path in.
- Failure simulation lives inside the application code; real chaos
  engineering (Chaos Mesh, AWS FIS) would inject failure at the
  network/infra level instead.
- Single environment (`dev`) -- no staging/prod split yet, though
  `environments/dev` sitting alongside shared `terraform/modules` is
  structured specifically to make adding one a new sibling folder, not a
  rewrite.
- **Alert routing currently goes to Slack only.** The `page` severity
  route should additionally go to a real paging system (PagerDuty,
  Opsgenie) in production -- a Slack message alone doesn't wake anyone up
  at 3am the way an actual page does. Called out explicitly here rather
  than left as a silent gap.
- **Loki runs in single-binary mode with local disk storage** -- fine for
  a dev environment; a production version would move to S3-backed,
  multi-tenant Loki for real horizontal scale and durability.
