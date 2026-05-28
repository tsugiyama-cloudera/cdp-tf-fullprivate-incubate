# Copyright 2025 Cloudera, Inc. All Rights Reserved.

variable "aws_region" {
  type        = string
  description = "Region which Cloud resources will be created"
}

variable "env_prefix" {
  type        = string
  description = "Shorthand name for the environment. Used in resource descriptions"

  validation {
    condition     = length(var.env_prefix) <= 12
    error_message = "The length of env_prefix must be 12 characters or less."
  }
  validation {
    condition     = can(regex("^[a-z0-9-]{1,12}$", var.env_prefix))
    error_message = "env_prefix can consist only of lowercase letters, numbers, and hyphens (-)."
  }
}

variable "aws_key_pair" {
  type        = string
  description = "Name of the Public SSH key for the CDP environment"
  default     = null
}

variable "env_tags" {
  type        = map(any)
  description = "Tags applied to provisioned resources"
  default     = null
}

variable "deployment_template" {
  type        = string
  description = "Deployment Pattern to use for Cloud resources and CDP"

  validation {
    condition     = contains(["public", "semi-private", "private"], var.deployment_template)
    error_message = "Valid values for var: deployment_template are (public, semi-private, private)."
  }
}

variable "ingress_extra_cidrs_and_ports" {
  type = object({
    cidrs = list(string)
    ports = list(number)
  })
  description = "List of extra CIDR blocks and ports to include in Security Group Ingress rules"
  default     = null
}

variable "create_vpc" {
  type        = bool
  description = "Flag to specify if the VPC should be created"
  default     = true
}

variable "cdp_vpc_id" {
  type        = string
  description = "VPC ID for CDP environment. Required if create_vpc is false."
  default     = null
}

variable "cdp_public_subnet_ids" {
  type        = list(any)
  description = "List of public subnet ids. Required if create_vpc is false."
  default     = null
}

variable "cdp_private_subnet_ids" {
  type        = list(any)
  description = "List of private subnet ids. Required if create_vpc is false."
  default     = null
}

variable "private_network_extensions" {
  type        = bool
  description = "Enable public subnet and NAT for private deployment template"
  default     = true
}

variable "create_vpc_endpoints" {
  type        = bool
  description = "Flag to specify if VPC Endpoints should be created"
  default     = true
}
