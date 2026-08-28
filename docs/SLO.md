# Service Level Objectives — txn-gateway

## Why define these first

Alerting rules and dashboards should be *derived from* SLOs, not the other
way around. Picking thresholds first and calling them SLOs after the fact
tends to produce noisy, meaningless alerts. So this doc comes before the
alerting rules file.

## SLIs (Service Level Indicators) — what we actually measure

| SLI | Definition | Measured via |
|---|---|---|
| **Availability** | % of transaction requests that settle successfully | `txn_requests_total{status="settled"} / txn_requests_total` |
| **Latency** | % of requests served under 300ms | `txn_request_duration_seconds_bucket` (histogram) |

## SLOs (Service Level Objectives) — the targets we commit to

| SLO | Target | Window |
|---|---|---|
| Availability | 99.5% of requests succeed | Rolling 30 days |
| Latency | 95% of requests complete in < 300ms | Rolling 30 days |

**Why 99.5%, not 99.9% or 99.99%:** deliberately realistic, not an
arbitrary "more nines is better" pick. Higher SLOs cost real engineering
effort (redundancy, retries, circuit breakers) and real money
(over-provisioning). 99.5% allows roughly **3.6 hours of downtime per
month** — defensible for a demo transaction gateway without
over-engineering the exercise. **In a real trading/payments platform**,
this number would never be picked by the SRE team in isolation — it would
come directly from the business's actual tolerance for settlement delay
or failure, likely informed by regulatory/SLA commitments to counterparties,
and would very plausibly land much higher (99.9%+) for anything touching
live trade execution specifically.

**Why latency gets equal billing with availability here:** for a typical
web app, a slow-but-successful request is a minor annoyance. For a
transaction gateway, a slow settlement can be operationally and financially
costly in its own right (stale pricing, missed execution windows) — so
this SLO set tracks latency as an independently important signal, not a
secondary concern to error rate.

## Error Budget

At 99.5% availability over 30 days:
- Total budget: 0.5% of requests may fail = **~3.6 hours of full downtime**
  (or an equivalent mix of partial degradation)
- **Policy**: if >50% of the monthly error budget is consumed in a single
  week, feature deploys pause and the team prioritizes reliability work
  until the burn rate normalizes. This is the mechanism that turns an SLO
  from a number on a dashboard into something that actually changes
  day-to-day engineering priorities.

## Why two separate alert types (see alerting-rules.yaml)

- **Fast-burn alert**: catches a sudden, severe outage (e.g. bad deploy)
  within minutes — high urgency, page immediately.
- **Slow-burn alert**: catches a low-grade but sustained problem (e.g. a
  memory leak causing gradual error creep) that a fast-burn alert would
  miss entirely because no single short window looks "bad enough" to fire
  — ticket/Slack notification, not a 3am page.

This two-speed pattern is the standard multi-window, multi-burn-rate
approach (as used by Google's SRE practice) precisely because a single
threshold either pages too often on noise or misses real slow-developing
incidents.
