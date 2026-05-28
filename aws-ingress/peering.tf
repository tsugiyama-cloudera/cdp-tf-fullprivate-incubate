# ------- Same-account VPC Peering: ops VPC → CDP VPC -------

resource "aws_vpc_peering_connection" "ops_to_cdp" {
  vpc_id      = aws_vpc.ops.id
  peer_vpc_id = var.peer_vpc_id
  auto_accept = true # same account → auto-accept

  tags = { Name = "pcx-${var.env_prefix}-ops-to-cdp" }
}

# Route from ops VPC → CDP VPC.
resource "aws_route" "ops_to_cdp" {
  route_table_id            = aws_route_table.ops.id
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.ops_to_cdp.id
}

# Route from CDP VPC → ops VPC. Added on CDP-side private route table looked up
# by Name tag. aws/ uses separate aws_route resources rather than inline `route`
# blocks inside aws_route_table, so no drift in aws/ state.
resource "aws_route" "cdp_to_ops" {
  route_table_id            = data.aws_route_table.cdp_private.id
  destination_cidr_block    = var.ops_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.ops_to_cdp.id
}
