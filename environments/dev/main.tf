# =============================================================================
# Network
# =============================================================================
module "vpc" {
  source = "../../terraform/modules/vpc"
  name   = "${var.env_name}-fintech"
}

# =============================================================================
# EKS cluster
# =============================================================================
module "eks" {
  source = "../../terraform/modules/eks"

  cluster_name = "${var.env_name}-eks"
  subnet_ids   = module.vpc.private_subnet_ids

  # Locked to the admin CIDR rather than left open to the internet.
  cluster_public_access_cidrs = compact([var.admin_cidr, var.ci_runner_cidr])

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}

# =============================================================================
# ECR — image repository for txn-gateway
# =============================================================================
resource "aws_ecr_repository" "txn_gateway" {
  name                 = "${var.env_name}-txn-gateway"
  image_tag_mutability = "IMMUTABLE" # fintech-appropriate: once a tag is pushed, it can't be silently overwritten
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "remediation_bot" {
  name                 = "${var.env_name}-remediation-bot"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
