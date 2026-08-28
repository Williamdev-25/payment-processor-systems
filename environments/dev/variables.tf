variable "region" {
  type    = string
  default = "us-east-1"
}

variable "env_name" {
  type    = string
  default = "dev"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach the EKS public API endpoint -- set to your own IP, never 0.0.0.0/0"
  type        = string
  default     = "203.0.113.4/32"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.small"]
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 6
}

variable "enable_monitoring" {
  type    = bool
  default = true
}

variable "enable_logging" {
  description = "Deploy Loki + Promtail for log aggregation"
  type        = bool
  default     = true
}

variable "monitoring_chart_version" {
  type    = string
  default = "62.7.0"
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = "changeme-in-ci"
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for alert routing. Override via TF_VAR_slack_webhook_url / CI secret."
  type        = string
  sensitive   = true
  default     = "https://hooks.slack.com/services/CHANGEME"
}

variable "ci_runner_cidr" {
  description = "Current GitHub Actions runner IP, fetched dynamically per CI run"
  type        = string
  default     = ""
}
