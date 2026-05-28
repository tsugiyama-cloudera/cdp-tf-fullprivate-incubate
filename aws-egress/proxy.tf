data "aws_iam_policy_document" "proxy_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy" {
  name               = "${var.env_prefix}-egress-proxy-role"
  assume_role_policy = data.aws_iam_policy_document.proxy_assume_role.json

  tags = { Name = "${var.env_prefix}-egress-proxy-role" }
}

resource "aws_iam_role_policy_attachment" "proxy_ssm" {
  role       = aws_iam_role.proxy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "proxy" {
  name = "${var.env_prefix}-egress-proxy-profile"
  role = aws_iam_role.proxy.name
}

resource "aws_security_group" "proxy" {
  name        = "${var.env_prefix}-egress-proxy-sg"
  description = "Allow proxy access from CDP VPC only."
  vpc_id      = aws_vpc.egress.id

  ingress {
    description = "Proxy access from CDP Workload VPC"
    from_port   = var.proxy_port
    to_port     = var.proxy_port
    protocol    = "tcp"
    cidr_blocks = [var.peer_vpc_cidr]
  }

  egress {
    description = "Allow outbound for proxy upstream access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.env_prefix}-egress-proxy-sg" }
}

resource "aws_instance" "proxy" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.proxy_instance_type
  subnet_id              = aws_subnet.egress_private.id
  private_ip             = local.proxy_private_ip
  vpc_security_group_ids = [aws_security_group.proxy.id]
  iam_instance_profile   = aws_iam_instance_profile.proxy.name

  associate_public_ip_address = false

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail

    dnf -y update
    dnf -y install squid

    cat <<'EOF_DOMAINS' >/etc/squid/allowed_domains.txt
    ${join("\n", local.normalized_allowed_fqdns)}
    EOF_DOMAINS

    cat <<'EOF_CONF' >/etc/squid/squid.conf
    visible_hostname egress-proxy
    http_port ${var.proxy_port}

    acl SSL_ports port 443
    acl Safe_ports port 80
    acl Safe_ports port 443
    acl CONNECT method CONNECT

    acl allowed_domains dstdomain "/etc/squid/allowed_domains.txt"
    acl allowed_server_names ssl::server_name "/etc/squid/allowed_domains.txt"

    http_access deny !Safe_ports
    http_access deny CONNECT !SSL_ports
    http_access allow CONNECT allowed_server_names
    http_access allow allowed_domains
    http_access deny all

    access_log /var/log/squid/access.log
    cache_log /var/log/squid/cache.log
    EOF_CONF

    systemctl enable squid
    systemctl restart squid
  EOT

  tags = {
    Name = "${var.env_prefix}-egress-proxy"
  }
}
