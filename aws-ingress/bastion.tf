# ------- IAM Role / Instance Profile for SSM Session Manager -------
data "aws_iam_policy_document" "bastion_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${var.env_prefix}-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume_role.json

  tags = { Name = "${var.env_prefix}-bastion-role" }
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.env_prefix}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ------- Bastion Security Group -------
# No inbound (SSM is outbound-only).
# Outbound: 443 to VPC Endpoints + Peered CDP VPC SSH/HTTPS.
resource "aws_security_group" "bastion" {
  name        = "${var.env_prefix}-bastion-sg"
  description = "Bastion EC2 - no inbound, outbound to SSM endpoints and peered CDP VPC"
  vpc_id      = aws_vpc.ops.id

  egress {
    description = "HTTPS to SSM Interface VPC Endpoints + general"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "SSH to peered CDP VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.peer_vpc_cidr]
  }

  egress {
    description = "HTTPS to peered CDP VPC (Knox / CM / etc.)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.peer_vpc_cidr]
  }

  tags = { Name = "${var.env_prefix}-bastion-sg" }
}

# ------- Bastion EC2 -------
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.bastion_instance_type
  subnet_id              = aws_subnet.ops_bastion.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  # Reuse the CDP env's keypair so the same .pem (aws/ntt-poc-ssh-key.pem) is
  # used both to SSH into CDP cluster nodes (cloudbreak@) and into the bastion
  # itself (ec2-user@). Avoids managing a separate bastion-only key.
  key_name = var.bastion_key_name

  associate_public_ip_address = false

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = {
    Name = "${var.env_prefix}-bastion"
  }
}
