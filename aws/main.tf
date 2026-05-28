# Copyright 2025 Cloudera, Inc. All Rights Reserved.
# Phase 3: CDP Environment deployment. Run aws-init first.

terraform {
  required_version = ">= 1.5.7"
  required_providers {
    cdp = {
      source  = "cloudera/cdp"
      version = ">= 0.6.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
  }
}

provider "aws" {
  region = var.aws_region

  ignore_tags {
    key_prefixes = ["kubernetes.io/cluster"]
  }
}

locals {
  cdp_groups = var.cdp_groups != null ? var.cdp_groups : toset([
    {
      name                   = "${var.env_prefix}-aw-cdp-admin-group"
      create_group           = true
      add_id_broker_mappings = true
    },
    {
      name                   = "${var.env_prefix}-aw-cdp-user-group"
      create_group           = true
      add_id_broker_mappings = true
    }
  ])

  init_public_subnets  = data.terraform_remote_state.init.outputs.aws_public_subnet_ids
  init_private_subnets = data.terraform_remote_state.init.outputs.aws_private_subnet_ids

  compute_cluster_configuration = var.compute_cluster_enabled ? (
    var.compute_cluster_configuration != null ? var.compute_cluster_configuration : {
      kube_api_authorized_ip_ranges = var.deployment_template == "private" ? null : null
      worker_node_subnets           = var.deployment_template == "public" ? concat(local.init_public_subnets, local.init_private_subnets) : local.init_private_subnets
      private_cluster               = var.deployment_template == "private" ? true : false
    }
  ) : null
}
