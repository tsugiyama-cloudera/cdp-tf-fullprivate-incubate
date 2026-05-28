output "egress_vpc_id" {
  value       = aws_vpc.egress.id
  description = "Egress VPC ID."
}

output "egress_proxy_private_ip" {
  value       = aws_instance.proxy.private_ip
  description = "Private IP of Squid proxy."
}

output "egress_proxy_url" {
  value       = "http://${aws_instance.proxy.private_ip}:${var.proxy_port}"
  description = "HTTP/HTTPS proxy URL for CDP workloads."
}

output "egress_peering_connection_id" {
  value       = aws_vpc_peering_connection.egress_to_cdp.id
  description = "Peering connection ID between Egress and CDP VPC."
}

output "egress_private_route_table_id" {
  value       = aws_route_table.egress_private.id
  description = "Route table ID attached to the proxy subnet."
}

output "mc_proxy_registration" {
  value = {
    proxy_config_name  = local.mc_proxy_config_name
    protocol           = "http"
    server_host        = aws_instance.proxy.private_ip
    server_port        = var.proxy_port
    no_proxy_hosts     = local.mc_proxy_no_proxy_hosts
    inbound_proxy_cidr = var.peer_vpc_cidr
  }
  description = "Recommended values for MC Shared Resources > Proxies registration."
}
