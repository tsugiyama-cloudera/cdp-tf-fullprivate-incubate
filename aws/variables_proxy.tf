# Proxy configuration for full-private CDP environment (additive file).

variable "proxy_config_name" {
  type        = string
  description = "Name of the proxy configuration registered in CDP Management Console (Shared Resources > Proxies). Required when deployment_template is private and private_network_extensions is false in aws-init."

  default = null

  validation {
    condition = (
      var.deployment_template != "private" ||
      var.private_network_extensions ||
      (var.proxy_config_name != null && length(trimspace(var.proxy_config_name)) > 0)
    )
    error_message = "For private deployment without NAT (private_network_extensions=false in aws-init), proxy_config_name must be set to a proxy already registered in CDP Management Console."
  }
}
