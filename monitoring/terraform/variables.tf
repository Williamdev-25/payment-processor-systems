variable "enable_monitoring" {
  type    = bool
  default = true
}

variable "enable_logging" {
  description = "Deploy Loki + Promtail for log aggregation, alongside metrics"
  type        = bool
  default     = true
}

variable "chart_version" {
  description = "kube-prometheus-stack Helm chart version -- pinned explicitly, never 'latest'"
  type        = string
  default     = "62.7.0"
}

variable "loki_chart_version" {
  type    = string
  default = "5.47.2"
}

variable "promtail_chart_version" {
  type    = string
  default = "6.16.6"
}

variable "metrics_retention" {
  type    = string
  default = "7d"
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = "changeme-in-ci"
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for Alertmanager notifications. Override via TF_VAR_slack_webhook_url / CI secret -- never commit a real value."
  type        = string
  sensitive   = true
  default     = "https://hooks.slack.com/services/CHANGEME"
}
