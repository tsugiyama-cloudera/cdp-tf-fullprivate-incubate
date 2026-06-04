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
    "api.ap-1.cdp.cloudera.com",                                      # CDP Control Plane API (ap-1)
    "*.v2.ccm.ap-1.cdp.cloudera.com",                                 # CCM v2 cluster communication (ap-1)
    "*.v2.us-west-1.ccm.cdp.cloudera.com",                            # Jumpgate relayServer / CCM v2 HA (us-west-1)
    "*.api.monitoring.ap-1.cdp.cloudera.com",                         # CDP monitoring APIs (ap-1)
    "*.us-west-1.cdp.cloudera.com",                                   # Control Plane / Liftie / Compute Cluster APIs (us-west-1)
    "*.monitoring.us-west-1.cdp.cloudera.com",                        # Control Plane monitoring (us-west-1)
    "dbusapi.us-west-1.sigma.altus.cloudera.com",                     # Sigma DBus telemetry for Liftie / EKS clusters
    "cloudformation.ap-northeast-1.amazonaws.com",                    # EKS worker cfn-signal (--https-proxy; VPC endpoint bypassed)
    "mow-prod-ap-southeast-2-sigmadbus-dbus.s3.ap-southeast-2.amazonaws.com", # Sigma DBus event bus (regional S3)
    "mow-prod-ap-southeast-2-sigmadbus-dbus.s3.amazonaws.com",        # Sigma DBus event bus (global S3)
    "archive.cloudera.com",                                           # Cloudera parcels / packages / RPM downloads
    "cloudera-service-delivery-cache.s3.amazonaws.com",               # Cloudera service delivery cache (S3)
    "prod-ap-southeast-1-starport-layer-bucket.s3.ap-southeast-1.amazonaws.com", # Starport container layer cache (regional)
    "prod-ap-southeast-1-starport-layer-bucket.s3.amazonaws.com",     # Starport container layer cache (global)
    "s3-r-w.ap-southeast-1.amazonaws.com",                            # S3 read/write endpoint for Starport layers
    "*.execute-api.ap-southeast-1.amazonaws.com",                     # API Gateway for Cloudera delivery services
    "container.repo.cloudera.com",                                    # Cloudera container registry (legacy hostname)
    "docker.repository.cloudera.com",                                 # Agent Studio ML Runtime image / CDSW engine images
    "container.repository.cloudera.com",                              # Cloudera container images (CDSW, Istio sidecar, etc.)
    "console.ap-1.cdp.cloudera.com",                                  # Cloudera Management Console API (ap-1)
    "raw.githubusercontent.com",                                      # GitHub raw content (AI Studios catalog, nvm install, AMPs)
    "github.com",                                                     # GitHub repos (AMPs, AI Studios, runtime config)
    "huggingface.co",                                                 # Hugging Face model hub (Model Hub import)
    "api.ngc.nvidia.com",                                             # NVIDIA NGC API (Model Hub)
    "files.ngc.nvidia.com",                                           # NVIDIA NGC model / artifact downloads
    "xfiles.ngc.nvidia.com",                                          # NVIDIA NGC extended file downloads
    "prod.otel.kaizen.nvidia.com",                                    # NVIDIA NGC telemetry (OpenTelemetry)
    "nvcr.io",                                                        # NVIDIA NGC Container Registry
    "ngc.nvidia.com",                                                 # NVIDIA NGC web / redirects
    "authn.nvidia.com",                                               # NVIDIA NGC authentication
    "github.infra.cloudera.com",                                      # Cloudera internal GitHub Enterprise
    "nodejs.org",                                                     # Node.js binaries (AI Studios / Agent Studio)
    "iojs.org",                                                       # io.js binaries (legacy Node.js)
    "pypi.org",                                                       # Python Package Index (pip install in Workbench)
    "files.pythonhosted.org",                                         # PyPI package file hosting
    "pypi.python.org",                                                # PyPI legacy hostname
    "test.pypi.org",                                                  # Test PyPI index
    "test-files.pythonhosted.org",                                    # Test PyPI package file hosting
    "bedrock-runtime.ap-northeast-1.amazonaws.com",                   # AWS Bedrock runtime (AI Studios / Synthetic Data Studio)
    "api.gradio.app",                                                 # Gradio API (model UI demos in Workbench)
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
