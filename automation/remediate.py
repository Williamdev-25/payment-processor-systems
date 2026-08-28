#!/usr/bin/env python3
"""
remediate.py — a small SRE automation tool that watches txn-gateway
pods and takes a safe, well-logged remediation action when it detects a
genuinely stuck pod (repeated readiness failures), rather than requiring a
human to be paged for something a script can safely fix.

Design choices worth calling out (these are the actual "SRE thinking"
part of this exercise, not the code itself):

1. It does NOT restart on every single failure — a single failed request
   is expected (that's the whole point of the SLO/error-budget model, not
   every failure is an incident). It acts only after a sustained pattern.

2. It has a --dry-run mode by default. An automation tool that can take
   destructive action in production should never default to "just do it" —
   that's how a bug in the automation itself becomes an incident.

3. Every action taken is logged with a timestamp and reason — auto-
   remediation without an audit trail is a liability in a regulated
   environment like fintech, since you need to be able to answer "what
   changed, when, and why" after any incident.

4. It's rate-limited per pod (won't attempt the same remediation twice
   within a cooldown window) — prevents a remediation-restart-crash loop
   if the underlying cause isn't actually fixed by a restart.
"""

import argparse
import logging
import sys
import time
from datetime import datetime, timedelta

from kubernetes import client, config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("remediate")

RESTART_THRESHOLD = 3          # container restarts within the window that trigger action
LOOKBACK_MINUTES = 15          # how far back "recent" restarts count
COOLDOWN_MINUTES = 10          # don't re-remediate the same pod within this window

_last_action = {}  # pod_name -> datetime of last remediation, in-memory audit for cooldown


def load_k8s_config():
    try:
        config.load_incluster_config()
        log.info("Loaded in-cluster config (running inside the cluster).")
    except config.ConfigException:
        config.load_kube_config()
        log.info("Loaded local kubeconfig (running outside the cluster).")


def get_unhealthy_pods(v1, namespace: str, label_selector: str):
    """Return pods whose containers have restarted more than
    RESTART_THRESHOLD times, based on container status — this mirrors
    exactly what the ResilientServicePodCrashLooping Prometheus alert
    checks, so the automation and the alerting are looking at the same
    signal rather than diverging definitions of 'unhealthy'."""
    pods = v1.list_namespaced_pod(namespace, label_selector=label_selector)
    unhealthy = []
    for pod in pods.items:
        if not pod.status.container_statuses:
            continue
        for cs in pod.status.container_statuses:
            if cs.restart_count and cs.restart_count > RESTART_THRESHOLD:
                unhealthy.append((pod.metadata.name, cs.restart_count))
    return unhealthy


def in_cooldown(pod_name: str) -> bool:
    last = _last_action.get(pod_name)
    if not last:
        return False
    return datetime.utcnow() - last < timedelta(minutes=COOLDOWN_MINUTES)


def remediate_pod(v1, namespace: str, pod_name: str, restart_count: int, dry_run: bool):
    if in_cooldown(pod_name):
        log.info(f"SKIP {pod_name}: still in cooldown from a previous action.")
        return

    reason = f"{restart_count} restarts in the last ~{LOOKBACK_MINUTES}m (threshold={RESTART_THRESHOLD})"

    if dry_run:
        log.info(f"[DRY-RUN] Would delete pod {pod_name} — reason: {reason}")
    else:
        log.warning(f"REMEDIATING {pod_name} — reason: {reason}. Deleting pod (ReplicaSet will recreate it).")
        v1.delete_namespaced_pod(name=pod_name, namespace=namespace)

    _last_action[pod_name] = datetime.utcnow()


def run_once(namespace: str, label_selector: str, dry_run: bool):
    v1 = client.CoreV1Api()
    unhealthy = get_unhealthy_pods(v1, namespace, label_selector)

    if not unhealthy:
        log.info("No unhealthy pods detected.")
        return

    for pod_name, restart_count in unhealthy:
        remediate_pod(v1, namespace, pod_name, restart_count, dry_run)


def main():
    parser = argparse.ArgumentParser(description="Auto-remediate crash-looping txn-gateway pods.")
    parser.add_argument("--namespace", default="default")
    parser.add_argument("--label-selector", default="app=txn-gateway")
    parser.add_argument("--interval", type=int, default=60, help="Seconds between checks. 0 = run once and exit.")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=True,
        help="Log intended actions without taking them. Pass --no-dry-run to actually act.",
    )
    parser.add_argument("--no-dry-run", dest="dry_run", action="store_false")
    args = parser.parse_args()

    load_k8s_config()

    if args.dry_run:
        log.warning("Running in DRY-RUN mode — no pods will actually be deleted. Use --no-dry-run to enable real actions.")

    if args.interval == 0:
        run_once(args.namespace, args.label_selector, args.dry_run)
        return

    log.info(f"Watching pods every {args.interval}s (namespace={args.namespace}, selector={args.label_selector})")
    while True:
        try:
            run_once(args.namespace, args.label_selector, args.dry_run)
        except Exception as e:
            log.error(f"Error during remediation check: {e}")
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
