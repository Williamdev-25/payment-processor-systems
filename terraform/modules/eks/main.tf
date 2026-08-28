resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    # Restrict who can reach the public API endpoint — wide open (0.0.0.0/0)
    # is the default but not appropriate for anything beyond a demo.
    public_access_cidrs = var.cluster_public_access_cidrs
  }

  # Control-plane audit/API logs to CloudWatch — off by default on EKS,
  # and one of the first things worth turning on for anything handling
  # real traffic, since it's what lets you answer "who did what" later.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_AmazonEKSClusterPolicy]
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = var.subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type # ON_DEMAND or SPOT
  ami_type       = "AL2023_x86_64_STANDARD" # AL2 AMIs no longer published by AWS as of Nov 2025

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1 # mirrors the same "never take down more than 1 at a time" pattern used in the ASG/deployment configs elsewhere in this project
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.eks_node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.eks_node_AmazonEC2ContainerRegistryReadOnly,
  ]
}



