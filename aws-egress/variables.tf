variable "env_prefix" {
  type        = string
  description = "Resource name prefix."
  default     = "ntt-poc"
}

variable "aws_region" {
  type        = string
  description = "AWS region for Egress VPC."
  default     = "ap-northeast-1"
}

variable "egress_profile" {
  type        = string
  description = "AWS CLI profile for Egress VPC deployment."
  default     = "cloudera-cdp-20250901"
}

variable "availability_zone" {
  type        = string
  description = "Availability zone to place Egress resources."
  default     = "ap-northeast-1a"
}

variable "egress_vpc_cidr" {
  type        = string
  description = "CIDR for Egress VPC."
  default     = "10.98.0.0/24"
}

variable "egress_public_subnet_cidr" {
  type        = string
  description = "CIDR for NAT subnet in Egress VPC."
  default     = "10.98.0.0/28"
}

variable "egress_private_subnet_cidr" {
  type        = string
  description = "CIDR for proxy subnet in Egress VPC."
  default     = "10.98.0.16/28"
}

variable "proxy_instance_type" {
  type        = string
  description = "EC2 instance type for Squid proxy."
  default     = "t3.small"
}

variable "proxy_port" {
  type        = number
  description = "Listening port of Squid proxy."
  default     = 3128
}

variable "proxy_private_ip" {
  type        = string
  description = "Fixed private IP for Squid proxy in egress_private_subnet_cidr. If null, the first assignable host in the subnet is used (cidrhost offset 4; AWS reserves offsets 0-3)."
  default     = null
}

variable "peer_vpc_id" {
  type        = string
  description = "CDP Workload VPC ID to peer with."
}

variable "peer_vpc_cidr" {
  type        = string
  description = "CIDR for CDP Workload VPC."
}

variable "peer_private_route_table_ids" {
  type        = list(string)
  description = "CDP VPC private route table IDs for peering routes. If null, read from aws-init remote state."
  default     = null
}

variable "allowed_fqdns" {
  type        = list(string)
  description = "Allowed destinations for proxy egress control."
  default = [
    "api.ap-1.cdp.cloudera.com",
    "*.v2.ccm.ap-1.cdp.cloudera.com",
    # Jumpgate relayServer (config.toml) uses account HA host in us-west-1, not ap-1.
    "*.v2.us-west-1.ccm.cdp.cloudera.com",
    "*.api.monitoring.ap-1.cdp.cloudera.com",
    # Control Plane / Liftie (us-west-1). Workload region ap-1 but CP APIs use us-west-1.
    "*.us-west-1.cdp.cloudera.com",
    "*.monitoring.us-west-1.cdp.cloudera.com",
    "dbusapi.us-west-1.sigma.altus.cloudera.com",
    # cfn-signal on EKS workers uses --https-proxy (VPC endpoint bypassed).
    "cloudformation.ap-northeast-1.amazonaws.com",
    "mow-prod-ap-southeast-2-sigmadbus-dbus.s3.ap-southeast-2.amazonaws.com",
    "mow-prod-ap-southeast-2-sigmadbus-dbus.s3.amazonaws.com",
    "archive.cloudera.com",
    "cloudera-service-delivery-cache.s3.amazonaws.com",
    "prod-ap-southeast-1-starport-layer-bucket.s3.ap-southeast-1.amazonaws.com",
    "prod-ap-southeast-1-starport-layer-bucket.s3.amazonaws.com",
    "s3-r-w.ap-southeast-1.amazonaws.com",
    "*.execute-api.ap-southeast-1.amazonaws.com",
    "container.repo.cloudera.com",
    "container.repository.cloudera.com",
    "console.ap-1.cdp.cloudera.com",
    "raw.githubusercontent.com",
    "github.com",
    "huggingface.co",
    "api.ngc.nvidia.com",
    "files.ngc.nvidia.com",
    "xfiles.ngc.nvidia.com",
    "prod.otel.kaizen.nvidia.com",
    "nvcr.io",
    "ngc.nvidia.com",
    "authn.nvidia.com",
    "github.infra.cloudera.com",
    "nodejs.org",
    "iojs.org",
    "pypi.org",
    "files.pythonhosted.org",
    "pypi.python.org",
    "test.pypi.org",
    "test-files.pythonhosted.org",
    "bedrock-runtime.ap-northeast-1.amazonaws.com",
    "api.gradio.app",
  ]
}

variable "env_tags" {
  type        = map(string)
  description = "Additional tags for resources."
  default     = null
}

variable "mc_proxy_no_proxy_hosts_extra" {
  type        = list(string)
  description = "Optional extra No Proxy hosts/CIDRs appended to mc_proxy_registration.no_proxy_hosts (e.g. datalake bucket FQDN if needed)."
  default     = []
}
