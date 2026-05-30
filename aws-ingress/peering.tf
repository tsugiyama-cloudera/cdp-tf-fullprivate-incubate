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

# Route from CDP VPC → ops VPC on each private route table (from aws-init output).
resource "aws_route" "cdp_to_ops" {
  for_each = toset(local.cdp_private_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.ops_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.ops_to_cdp.id
}
