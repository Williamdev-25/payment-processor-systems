output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "oidc_provider_arn" {
  description = "Needed by any module/resource setting up IRSA (e.g. AWS Load Balancer Controller, External Secrets Operator)"
  value       = aws_iam_openid_connect_provider.eks_oidc.arn
}

output "oidc_issuer_url" {
  value = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "node_group_role_arn" {
  value = aws_iam_role.eks_node_group.arn
}
