# =============================================================================
# Monitoring — delegates to the standalone monitoring module
# =============================================================================
# See monitoring/MONITORING.md for the full observability strategy
# (dashboards, alert design, why they're split the way they are).
module "monitoring" {
  source = "../../monitoring/terraform"

  enable_monitoring      = var.enable_monitoring
  enable_logging         = var.enable_logging
  chart_version          = var.monitoring_chart_version
  grafana_admin_password = var.grafana_admin_password
  slack_webhook_url      = var.slack_webhook_url

  depends_on = [module.eks]
}
