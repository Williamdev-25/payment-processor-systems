output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "ecr_txn_gateway_repo_url" {
  value = aws_ecr_repository.txn_gateway.repository_url
}

output "ecr_remediation_bot_repo_url" {
  value = aws_ecr_repository.remediation_bot.repository_url
}

output "grafana_access_note" {
  value = module.monitoring.grafana_access_note
}
