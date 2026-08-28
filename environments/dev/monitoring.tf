# =============================================================================
# Monitoring — delegates to the standalone monitoring module
# =============================================================================
resource "time_sleep" "wait_for_eks_endpoint" {
  depends_on      = [module.eks]
  create_duration = "60s"
}

module "monitoring" {
  source = "../../monitoring/terraform"

  enable_monitoring      = var.enable_monitoring
  enable_logging         = var.enable_logging
  chart_version          = var.monitoring_chart_version
  grafana_admin_password = var.grafana_admin_password
  slack_webhook_url      = var.slack_webhook_url

  depends_on = [time_sleep.wait_for_eks_endpoint]
}