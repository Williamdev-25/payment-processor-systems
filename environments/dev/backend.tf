terraform {
  required_version = ">= 1.10"
  backend "s3" {
    bucket       = "fintech-sre-platform-tfstate"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
