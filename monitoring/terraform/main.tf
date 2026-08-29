# =============================================================================
# Monitoring Module — kube-prometheus-stack + provisioned dashboards
# =============================================================================
# Pulled out as its own module rather than inline resources in
# environment/dev, for two reasons:
#   1. Observability is a first-class piece of this platform's design, not
#      an afterthought bolted onto the environment config.
#   2. A real second environment (staging/prod) would want the exact same
#      monitoring setup with different sizing -- that's what a module is for.

resource "kubernetes_namespace" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  metadata {
    name   = "monitoring"
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.enable_monitoring ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_version
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          retention = var.metrics_retention
          resources = {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources   = { requests = { storage = "10Gi" } }
              }
            }
          }
        }
      }
      grafana = {
        adminPassword = var.grafana_admin_password
        service = {
          type        = "LoadBalancer"
          annotations = { "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb" }
        }
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
        defaultDashboardsEnabled = true
        # Sidecar watches for ConfigMaps labeled grafana_dashboard=1 across
        # the cluster and auto-loads them -- this is what makes the two
        # dashboards below appear in Grafana automatically on apply, with
        # no manual "import dashboard" click-ops step required.
        # Datasource sidecar -- lets the Loki datasource (added below) get
        # auto-provisioned the same way dashboards are, via a labeled
        # ConfigMap, rather than manually added through the Grafana UI.
        sidecar = {
          dashboards = {
            enabled         = true
            label           = "grafana_dashboard"
            labelValue      = "1"
            searchNamespace = "ALL"
          }
          datasources = {
            enabled    = true
            label      = "grafana_datasource"
            labelValue = "1"
          }
        }
      }
      alertmanager = {
        alertmanagerSpec = {
          resources = {
            requests = { cpu = "25m", memory = "64Mi" }
            limits   = { cpu = "100m", memory = "128Mi" }
          }
        }
        # Real alert routing, not just "deploy Alertmanager and stop there".
        # Severity comes straight from the labels set on every alert in
        # monitoring/alerts/ -- "page" routes to a paging channel with fast
        # repeat, "ticket" routes to a non-urgent channel with slow repeat.
        config = {
          global = {
            resolve_timeout = "5m"
          }
          route = {
            group_by        = ["alertname", "slo"]
            group_wait      = "30s"
            group_interval  = "5m"
            repeat_interval = "4h"
            receiver        = "default-ticket"
            routes = [
              {
                match           = { severity = "page" }
                receiver        = "paging-channel"
                repeat_interval = "15m"
                continue        = false
              },
              {
                match           = { severity = "ticket" }
                receiver        = "default-ticket"
                repeat_interval = "4h"
              }
            ]
          }
          receivers = [
            {
              name = "default-ticket"
              slack_configs = [{
                api_url       = var.slack_webhook_url
                channel       = "#txn-gateway-alerts"
                send_resolved = true
                title         = "{{ .CommonAnnotations.summary }}"
                text          = "{{ .CommonAnnotations.description }}\nRunbook: {{ .CommonAnnotations.runbook }}"
              }]
            },
            {
              name = "paging-channel"
              slack_configs = [{
                api_url       = var.slack_webhook_url
                channel       = "#txn-gateway-page"
                send_resolved = true
                title         = "🚨 {{ .CommonAnnotations.summary }}"
                text          = "{{ .CommonAnnotations.description }}\nRunbook: {{ .CommonAnnotations.runbook }}"
              }]
              # A real production setup would add pagerduty_configs here too,
              # with the "page" route being the only one wired to it --
              # Slack alone isn't a real page, it's a notification.
            }
          ]
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# =============================================================================
# Dashboards — provisioned as code, not manually clicked into existence
# =============================================================================
# Two dashboards, two different audiences:
#   - golden-signals: what an on-call engineer watches during an incident
#     (the four golden signals: latency, traffic, errors, saturation)
#   - business-metrics: what a non-SRE stakeholder cares about (settlement
#     volume, failure impact) -- see monitoring/MONITORING.md for why both
#     exist and who each one is actually for.

resource "kubernetes_config_map" "golden_signals_dashboard" {
  count = var.enable_monitoring ? 1 : 0

  metadata {
    name      = "txn-gateway-golden-signals-dashboard"
    namespace = kubernetes_namespace.monitoring[0].metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }

  data = {
    "golden-signals-dashboard.json" = file("${path.module}/../dashboards/golden-signals-dashboard.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "business_metrics_dashboard" {
  count = var.enable_monitoring ? 1 : 0

  metadata {
    name      = "txn-gateway-business-metrics-dashboard"
    namespace = kubernetes_namespace.monitoring[0].metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }

  data = {
    "business-metrics-dashboard.json" = file("${path.module}/../dashboards/business-metrics-dashboard.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# =============================================================================
# Logs — Loki + Promtail
# =============================================================================
# Metrics tell you WHAT is happening (error rate spiked). Logs tell you WHY
# (the actual stack trace / error message behind that spike). Deployed as
# two separate charts, mirroring the standard reference setup: Loki (the
# log store, single-binary mode -- appropriate for a dev environment, a
# multi-tenant/microservices-mode Loki would be the production upgrade),
# and Promtail (a DaemonSet that tails every node's container logs and
# ships them to Loki with pod/namespace/container labels attached).

resource "helm_release" "loki" {
  count = var.enable_monitoring && var.enable_logging ? 1 : 0

  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name

  timeout = 600
  atomic  = false
  wait    = false

  values = [
    yamlencode({
      deploymentMode = "SingleBinary"
      loki = {
        auth_enabled = false
        commonConfig = { replication_factor = 1 }
        storage      = { type = "filesystem" }
        schemaConfig = {
          configs = [{
            from   = "2024-01-01"
            store  = "tsdb"
            object_store = "filesystem"
            schema = "v13"
            index  = { prefix = "loki_index_", period = "24h" }
          }]
        }
      }
      singleBinary = {
        replicas = 1
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        persistence = { enabled = true, size = "10Gi" }
      }
      read    = { replicas = 0 }
      write   = { replicas = 0 }
      backend = { replicas = 0 }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

resource "helm_release" "promtail" {
  count = var.enable_monitoring && var.enable_logging ? 1 : 0

  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = var.promtail_chart_version
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name

  values = [
    yamlencode({
      config = {
        clients = [{
          url = "http://loki:3100/loki/api/v1/push"
        }]
      }
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    })
  ]

  depends_on = [helm_release.loki]
}

# Registers Loki as a Grafana datasource automatically -- same
# labeled-ConfigMap + sidecar pattern as the dashboards above, so there's
# no manual "add datasource" click-ops step for logs either.
resource "kubernetes_config_map" "loki_datasource" {
  count = var.enable_monitoring && var.enable_logging ? 1 : 0

  metadata {
    name      = "loki-datasource"
    namespace = kubernetes_namespace.monitoring[0].metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion  = 1
      datasources = [{
        name      = "Loki"
        type      = "loki"
        access    = "proxy"
        url       = "http://loki:3100"
        isDefault = false
      }]
    })
  }

  depends_on = [helm_release.loki]
}
