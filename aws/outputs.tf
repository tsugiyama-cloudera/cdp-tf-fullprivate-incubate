output "aws_vpc_id" {
  value       = data.terraform_remote_state.init.outputs.aws_vpc_id
  description = "AWS VPC ID (from aws-init)"
}

output "aws_vpc_cidr" {
  value       = data.terraform_remote_state.init.outputs.aws_vpc_cidr
  description = "CDP VPC CIDR (from aws-init)"
}
