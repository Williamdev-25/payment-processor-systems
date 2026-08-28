"""
txn-gateway — a small HTTP service standing in for a fintech transaction
gateway (the kind of component that sits in front of order/trade
processing). Its business logic is deliberately minimal; the point of
this service is to be a realistic, observable, occasionally-failing
system to build SRE practices around -- not to actually process trades.

It simulates two realistic production behaviours, both configurable via
env vars so failure/latency thresholds can be tuned without a code change:
  - FAILURE_RATE  -- a small % of transactions fail (e.g. downstream
                     ledger/settlement timeout)
  - SLOW_RATE     -- a small % of transactions are artificially slow
                     (e.g. a downstream dependency under load)

In a real trading platform, latency and correctness are not equally
weighted concerns the way they might be for a typical web app -- a slow
transaction can be as costly as a failed one. That's reflected in the
SLOs (docs/SLO.md) and alerting (k8s/prometheusrule.yaml) built around
this service, which track latency and error rate as two independently
important signals, not latency-as-an-afterthought.
"""

import json
import logging
import os
import random
import sys
import time
import uuid

from flask import Flask, Response, jsonify, request
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

# Structured JSON logging to stdout -- this is what Promtail actually
# tails (container stdout -> /var/log/containers/... -> Promtail -> Loki).
# Plain unstructured text logs work too, but JSON means LogQL queries can
# filter on real fields (status, txn_id) instead of doing fragile string
# matching against free-form text.
class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "timestamp": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname.lower(),
            "message": record.getMessage(),
        }
        if hasattr(record, "txn_id"):
            payload["txn_id"] = record.txn_id
        if hasattr(record, "status"):
            payload["status"] = record.status
        if hasattr(record, "duration_ms"):
            payload["duration_ms"] = record.duration_ms
        return json.dumps(payload)


log = logging.getLogger("txn-gateway")
log.setLevel(logging.INFO)
_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(JsonFormatter())
log.addHandler(_handler)

FAILURE_RATE = float(os.getenv("FAILURE_RATE", "0.05"))
SLOW_RATE = float(os.getenv("SLOW_RATE", "0.03"))
SLOW_LATENCY_MS = int(os.getenv("SLOW_LATENCY_MS", "800"))

TXN_COUNT = Counter(
    "txn_requests_total", "Total transaction requests", ["status"]
)
TXN_LATENCY = Histogram(
    "txn_request_duration_seconds", "Transaction processing latency"
)

# Simulates a stuck/degraded process the remediation bot can detect and
# act on, without actually crashing the pod -- lets the full alerting +
# remediation loop be demoed safely and on demand.
_state = {"forced_unhealthy": False}


@app.route("/transactions", methods=["POST"])
def process_transaction():
    start = time.time()
    txn_id = str(uuid.uuid4())

    if random.random() < SLOW_RATE:
        time.sleep(SLOW_LATENCY_MS / 1000)

    if _state["forced_unhealthy"] or random.random() < FAILURE_RATE:
        duration_ms = round((time.time() - start) * 1000, 1)
        TXN_COUNT.labels(status="failed").inc()
        TXN_LATENCY.observe(time.time() - start)
        log.error(
            "transaction failed: downstream settlement timeout",
            extra={"txn_id": txn_id, "status": "failed", "duration_ms": duration_ms},
        )
        return jsonify(txn_id=txn_id, status="failed", error="downstream settlement timeout"), 500

    duration_ms = round((time.time() - start) * 1000, 1)
    TXN_COUNT.labels(status="settled").inc()
    TXN_LATENCY.observe(time.time() - start)
    log.info(
        "transaction settled",
        extra={"txn_id": txn_id, "status": "settled", "duration_ms": duration_ms},
    )
    return jsonify(txn_id=txn_id, status="settled"), 200


@app.route("/healthz")
def healthz():
    """Liveness -- is the process fundamentally stuck? Deliberately
    unaffected by FAILURE_RATE: a flaky downstream dependency should
    never be conflated with 'this process needs to be killed and
    restarted', which is what liveness probes actually decide."""
    if _state["forced_unhealthy"]:
        return jsonify(status="unhealthy"), 500
    return jsonify(status="ok"), 200


@app.route("/readyz")
def readyz():
    """Readiness -- should traffic be routed here right now? Kept as a
    separate check from liveness on purpose."""
    if _state["forced_unhealthy"]:
        return jsonify(status="not ready"), 503
    return jsonify(status="ready"), 200


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.route("/admin/break", methods=["POST"])
def break_service():
    """Test/demo hook only -- forces a stuck state so the alerting and
    remediation pipeline have something real to react to on demand."""
    _state["forced_unhealthy"] = True
    return jsonify(message="service marked unhealthy"), 200


@app.route("/admin/fix", methods=["POST"])
def fix_service():
    _state["forced_unhealthy"] = False
    return jsonify(message="service marked healthy"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
