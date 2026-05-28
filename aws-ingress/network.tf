# ------- Ops VPC -------
resource "aws_vpc" "ops" {
  cidr_block           = var.ops_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.env_prefix}-ops-vpc" }
}

# Single private subnet (no NAT, no IGW). Outbound only via VPC Endpoints + peering.
resource "aws_subnet" "ops_bastion" {
  vpc_id                  = aws_vpc.ops.id
  cidr_block              = var.ops_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "subnet-${var.env_prefix}-ops-01" }
}

resource "aws_route_table" "ops" {
  vpc_id = aws_vpc.ops.id
  tags   = { Name = "rt-${var.env_prefix}-ops" }
}

resource "aws_route_table_association" "ops" {
  subnet_id      = aws_subnet.ops_bastion.id
  route_table_id = aws_route_table.ops.id
}

# ------- VPC Endpoints for SSM (Interface type) -------
# Lets bastion's SSM agent reach Systems Manager without any NAT / IGW.
# Three endpoints are required: ssm, ssmmessages, ec2messages.

resource "aws_security_group" "vpce" {
  name        = "${var.env_prefix}-ops-vpce-sg"
  description = "Allow HTTPS from ops subnet to Interface VPC Endpoints"
  vpc_id      = aws_vpc.ops.id

  ingress {
    description = "HTTPS from ops subnet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.ops_vpc_cidr]
  }

  egress {
    description = "Stateful ESTABLISHED responses (all outbound)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.env_prefix}-ops-vpce-sg" }
}

locals {
  ssm_services = ["ssm", "ssmmessages", "ec2messages"]
}

resource "aws_vpc_endpoint" "ssm_interface" {
  for_each = toset(local.ssm_services)

  vpc_id              = aws_vpc.ops.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.ops_bastion.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Name = "vpce-${var.env_prefix}-ops-${each.key}" }
}
