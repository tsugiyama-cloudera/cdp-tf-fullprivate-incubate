resource "aws_vpc" "egress" {
  cidr_block           = var.egress_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.env_prefix}-egress-vpc" }
}

resource "aws_internet_gateway" "egress" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "igw-${var.env_prefix}-egress" }
}

resource "aws_subnet" "egress_public" {
  vpc_id                  = aws_vpc.egress.id
  cidr_block              = var.egress_public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = { Name = "subnet-${var.env_prefix}-egress-public-01" }
}

resource "aws_subnet" "egress_private" {
  vpc_id                  = aws_vpc.egress.id
  cidr_block              = var.egress_private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "subnet-${var.env_prefix}-egress-private-01" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "eip-${var.env_prefix}-egress-nat" }
}

resource "aws_nat_gateway" "egress" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.egress_public.id

  tags = { Name = "nat-${var.env_prefix}-egress" }

  depends_on = [aws_internet_gateway.egress]
}

resource "aws_route_table" "egress_public" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "rt-${var.env_prefix}-egress-public" }
}

resource "aws_route" "egress_public_default" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.egress.id
}

resource "aws_route_table_association" "egress_public" {
  subnet_id      = aws_subnet.egress_public.id
  route_table_id = aws_route_table.egress_public.id
}

resource "aws_route_table" "egress_private" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "rt-${var.env_prefix}-egress-private" }
}

resource "aws_route" "egress_private_default" {
  route_table_id         = aws_route_table.egress_private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.egress.id
}

resource "aws_route_table_association" "egress_private" {
  subnet_id      = aws_subnet.egress_private.id
  route_table_id = aws_route_table.egress_private.id
}
