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
  profile = var.egress_profile

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

locals {
  normalized_allowed_fqdns = distinct([
    for domain in var.allowed_fqdns :
    startswith(replace(replace(lower(trimspace(domain)), "https://", ""), "http://", ""), "*.") ?
    replace(replace(replace(lower(trimspace(domain)), "https://", ""), "http://", ""), "*.", ".") :
    replace(replace(lower(trimspace(domain)), "https://", ""), "http://", "")
  ])
  # Fixed private IP for stable MC proxy registration.
  # AWS reserves the first 4 addresses in each subnet (network, router, DNS, future).
  proxy_private_ip        = coalesce(var.proxy_private_ip, cidrhost(var.egress_private_subnet_cidr, 4))
  mc_proxy_config_name = "${var.env_prefix}-egress-proxy"
  # Comma-separated, no spaces (Cloudera MC Proxy registration format).
  # Same-region S3/STS/ECR use VPC endpoints (no_proxy). Cross-region AWS (e.g. Starport
  # prod-ap-southeast-1-starport-layer-bucket.s3.ap-southeast-1.amazonaws.com) must use Squid.
  # Do not add blanket ".amazonaws.com" — it bypasses proxy for all AWS hosts including ap-southeast-1 S3.
  mc_proxy_no_proxy_hosts = join(",", concat(
    [
      "localhost",
      "127.0.0.1",
      "169.254.169.254",
      ".internal",
      ".svc",
      ".cluster.local",
      ".cloudera.site",
      ".s3.amazonaws.com",
      "s3.amazonaws.com",
      ".s3.${var.aws_region}.amazonaws.com",
      "s3.${var.aws_region}.amazonaws.com",
      "api.ecr.${var.aws_region}.amazonaws.com",
      "dkr.ecr.${var.aws_region}.amazonaws.com",
      "ec2.${var.aws_region}.amazonaws.com",
      ".${var.aws_region}.eks.amazonaws.com",
      "sts.amazonaws.com",
      "sts.${var.aws_region}.amazonaws.com",
    ],
    [var.peer_vpc_cidr, var.egress_vpc_cidr],
    var.mc_proxy_no_proxy_hosts_extra
  ))
}
