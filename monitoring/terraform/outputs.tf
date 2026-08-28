output "namespace" {
  value = var.enable_monitoring ? kubernetes_namespace.monitoring[0].metadata[0].name : null
}

output "grafana_access_note" {
  value = var.enable_monitoring ? "Run: kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'  |  Login: admin / <grafana_admin_password var>" : "monitoring not enabled"
}

output "logging_enabled" {
  value = var.enable_monitoring && var.enable_logging
}
