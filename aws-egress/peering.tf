resource "aws_vpc_peering_connection" "egress_to_cdp" {
  vpc_id      = aws_vpc.egress.id
  peer_vpc_id = var.peer_vpc_id
  auto_accept = true

  tags = { Name = "pcx-${var.env_prefix}-egress-to-cdp" }
}

resource "aws_route" "egress_to_cdp" {
  route_table_id            = aws_route_table.egress_private.id
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.egress_to_cdp.id
}

resource "aws_route" "cdp_to_egress" {
  route_table_id            = data.aws_route_table.cdp_private.id
  destination_cidr_block    = var.egress_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.egress_to_cdp.id
}
