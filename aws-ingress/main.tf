# aws-ops: Bastion + Ops VPC inside the same AWS account as the CDP env.
#
# Lifecycle: ops VPC is a *separate VPC* from the CDP VPC but lives in the same
# account (cloudera-cdp-20250901). Destroying / rebuilding the CDP env does NOT
# touch this ops VPC, as long as the CDP private route table keeps the same
# Name tag (`rt-ntt-poc-private`); the same-account peering is auto-accepted.

terraform {
  required_version = ">= 1.5.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.ops_profile

  default_tags {
    tags = merge({
      ManagedBy = "terraform"
    }, coalesce(var.env_tags, {}))
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
