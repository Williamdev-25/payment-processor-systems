variable "cluster_name" {
  description = "The name of the EKS cluster"
  type        = string
  default     = "my-eks-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.30"
}

variable "subnet_ids" {
  description = "A list of subnet IDs for the EKS cluster and node group"
  type        = list(string)
  default     = []
}

variable "cluster_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS API endpoint. Lock this down to known office/VPN IPs for anything beyond a demo."
  type        = list(string)
  default     = ["0.0.0.0/0"] # deliberately permissive default -- see note above; override in environment/dev
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"
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
