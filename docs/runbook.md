# Runbook — txn-gateway

Each section below maps directly to an alert defined in
`monitoring/alerts/prometheusrule.yaml`. The alert's `runbook` annotation links here so
whoever is paged has an immediate, specific next step — not a generic
"go investigate" with no starting point.

---

## Fast-Burn Error Rate

**Alert:** `ResilientServiceFastBurnErrorRate` · **Severity:** page

**What it means:** Something changed suddenly and badly — most likely a
bad deploy, a dependency outage, or a config error just rolled out.

**Immediate steps:**
1. Check recent deploys first: `kubectl rollout history deployment/txn-gateway`
   — if a deploy went out in the last ~15 minutes, that's the prime suspect.
2. If a recent deploy is the likely cause: `kubectl rollout undo deployment/txn-gateway`
   (see the rollback discussion from earlier — this is exactly that
   pattern in practice).
3. Check pod status: `kubectl get pods -l app=txn-gateway` — are pods
   actually crash-looping (see below), or up but returning errors?
4. Check Grafana dashboard for the error rate breakdown by pod — is it all
   pods, or one? All pods pointing to a bad deploy/shared dependency; one
   pod pointing to a node-level issue.
5. If not deploy-related, check upstream dependencies (database, external
   APIs) for their own outage signals.

**Do not** wait for the automation (`remediate.py`) to handle this — it
only targets crash-looping pods specifically, not elevated error rates
from otherwise-running pods. This alert needs a human decision.

---

## Slow-Burn Error Rate

**Alert:** `ResilientServiceSlowBurnErrorRate` · **Severity:** ticket (not page)

**What it means:** A lower-grade, sustained problem — the kind that won't
trip a fast-burn threshold but will quietly eat the monthly error budget.

**Steps (next business day is fine, this doesn't need a 3am response):**
1. Pull the 7-day error rate trend from Grafana — is this new, or has it
   been slowly climbing? A slow climb often points to a resource leak
   (check memory/CPU trend per pod) rather than a single bad change.
2. Check `kubectl describe hpa txn-gateway-hpa` — is autoscaling
   struggling to keep up with load, causing overload-driven errors?
3. File a ticket referencing the specific burn-rate window and current
   error-budget consumption (visible on the Grafana SLO dashboard) so
   the team can prioritize against the policy in `docs/SLO.md`.

---

## High Latency

**Alert:** `ResilientServiceHighLatency` · **Severity:** ticket

**Steps:**
1. Check if this correlates with a traffic spike (Grafana request-rate
   panel) — could just be legitimate load the HPA hasn't caught up to yet.
2. Check `kubectl top pods -l app=txn-gateway` for CPU throttling —
   if pods are hitting their CPU limit, that directly causes latency
   before it causes visible errors.
3. If load-related and persistent, consider raising `maxReplicas` on the
   HPA (`k8s/deployment.yaml`) or the per-pod CPU limit, depending on
   which resource is actually the bottleneck.

---

## Crash-Looping Pod

**Alert:** `ResilientServicePodCrashLooping` · **Severity:** page

**What it means:** A pod has restarted more than 3 times in 15 minutes —
`remediate.py` is watching for exactly this and will act automatically.

**Steps:**
1. Confirm the automation actually acted:
   `kubectl logs -l app=remediation-bot --tail=50` — look for a
   `REMEDIATING` log line for the affected pod.
2. If the bot's action (pod delete → ReplicaSet recreates it) resolved it,
   this alert should self-clear within a few minutes — no further action
   needed, but leave a note in the incident channel for the record.
3. **If the same pod (or its replacement) crash-loops again shortly
   after remediation** — the cooldown window means the bot won't keep
   hammering it. This is your signal that a restart alone isn't fixing
   the underlying cause. Pull logs from the pod immediately before it was
   deleted: `kubectl logs <pod-name> --previous`
4. Escalate to whoever owns the most recent code/config change if the
   root cause isn't obvious from logs.

---

## General principle across all of the above

Every alert here links back to a specific, numbered SLI/SLO in
`docs/SLO.md` — the point of that traceability is that nobody should ever
be paged for a number that doesn't map to an actual user-facing
commitment the team has agreed to. If an alert fires and doesn't map
cleanly to real user impact, that's a signal the alert itself needs
tuning, not that the runbook needs a new "just check Slack" step.

---

## Infrastructure alerts (monitoring/alerts/infra-alerts.yaml)

These are deliberately **not** SLO-derived — they're basic cluster-health
checks that sit underneath every application alert above. An app can look
perfectly healthy on its own SLOs right up until the node it's running on
runs out of disk.

### Node Down

**Alert:** `NodeDown` · **Severity:** page

**Steps:**
1. Check the AWS console / `aws eks describe-nodegroup` — is this a
   genuine EC2 instance failure, or an AZ-level AWS issue?
2. `kubectl get nodes` — confirm the node shows `NotReady`.
3. The managed node group should self-heal (EKS replaces unhealthy nodes
   automatically) — confirm a replacement is being provisioned before
   escalating further.
4. If pods that were on this node haven't been rescheduled within a few
   minutes, check `kubectl get pods -o wide` for anything stuck
   `Terminating` or `Pending`.

### Node Memory High

**Alert:** `NodeMemoryHighUsage` · **Severity:** ticket

**Steps:**
1. `kubectl top pods --all-namespaces --sort-by=memory` — identify what's
   actually consuming memory on the affected node.
2. Check whether it's `txn-gateway` itself (its resource limits should
   prevent this — if it's happening, the limits in `k8s/deployment.yaml`
   may need revisiting) or something else in the `monitoring` namespace
   (Prometheus/Loki are the two components most likely to grow with
   retained data over time).

### Node Disk Space (Warning / Critical)

**Alert:** `NodeDiskSpaceWarning` (80%) / `NodeDiskSpaceCritical` (95%) ·
**Severity:** ticket / page

**Steps:**
1. `kubectl describe node <node>` — check for disk-pressure taints.
2. Most common cause on a monitoring-heavy cluster: Prometheus or Loki's
   local persistent volumes filling up faster than expected — check their
   PVC usage specifically before assuming it's application-related.
3. At 95% (critical), the kubelet may start evicting pods to reclaim
   space — treat this as urgent, not just "clean up when convenient."

### PersistentVolume Usage (Warning / Critical)

**Alert:** `PersistentVolumeUsageWarning` (80%) /
`PersistentVolumeUsageCritical` (95%) · **Severity:** ticket / page

**Steps:**
1. Identify which PVC — `{{ $labels.persistentvolumeclaim }}` in the
   alert. This is very likely either Prometheus's own metrics storage or
   Loki's log storage, both of which grow continuously by design.
2. Short-term fix: reduce `metrics_retention` (Prometheus) via the
   monitoring module's variables, or check Loki's retention config.
3. Longer-term fix: increase the PVC size in `monitoring/terraform/main.tf`
   (Prometheus) — this requires the underlying StorageClass to support
   volume expansion.

### Deployment Not Available

**Alert:** `DeploymentNotAvailable` · **Severity:** page

**Steps:**
1. `kubectl get pods -l app=txn-gateway` — zero ready replicas means
   every single pod is failing its readiness probe simultaneously, not
   just one.
2. `kubectl describe deployment txn-gateway` and `kubectl logs` on any
   pod — check for a bad image (a broken deploy that passed the CI
   smoke tests but fails in the cluster's actual environment), a
   crashed dependency, or a config/secret that failed to mount.
3. If a recent deploy is the cause, this converges with the **Fast-Burn
   Error Rate** section above — `kubectl rollout undo deployment/txn-gateway`.
