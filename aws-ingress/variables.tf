variable "env_prefix" {
  type        = string
  description = "Resource name prefix. Bastion EC2 will be tagged <env_prefix>-bastion."
  default     = "ntt-poc"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "ops_profile" {
  type        = string
  description = "AWS CLI profile that owns both the ops VPC and the CDP VPC (same account)."
  default     = "cloudera-cdp-20250901"
}

# ------- Ops VPC -------
variable "ops_vpc_cidr" {
  type        = string
  description = "CIDR for the ops VPC. Must not overlap with any peered VPC or on-prem networks."
  default     = "10.99.0.0/24"
}

variable "ops_subnet_cidr" {
  type        = string
  description = "CIDR for the bastion subnet inside the ops VPC."
  default     = "10.99.0.0/28"
}

variable "availability_zone" {
  type    = string
  default = "ap-northeast-1a"
}

# ------- Bastion -------
variable "bastion_instance_type" {
  type    = string
  default = "t3.small"
}

variable "bastion_key_name" {
  type        = string
  description = "Name of an existing AWS EC2 keypair to authorize for ec2-user@bastion (defaults to the CDP env's keypair, created by aws/ terraform)."
  default     = "ntt-poc-keypair"
}

# ------- Peering target (NTT-PoC CDP VPC, same account) -------
variable "peer_vpc_id" {
  type        = string
  description = "VPC ID of the CDP env to peer with (in the same account as ops VPC)."
  default     = "vpc-0ec7e6b20176438c6"
}

variable "peer_vpc_cidr" {
  type        = string
  description = "CIDR of the CDP VPC (used in route table on ops side)."
  default     = "10.20.0.0/16"
}

variable "peer_private_route_table_ids" {
  type        = list(string)
  description = "CDP VPC private route table IDs for peering routes. If null, read from aws-init remote state."
  default     = null
}

variable "env_tags" {
  type    = map(string)
  default = null
}
