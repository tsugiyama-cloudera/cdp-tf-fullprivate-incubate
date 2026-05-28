output "ops_vpc_id" {
  value = aws_vpc.ops.id
}

output "ops_subnet_id" {
  value = aws_subnet.ops_bastion.id
}

output "bastion_instance_id" {
  value       = aws_instance.bastion.id
  description = "Use with: aws ssm start-session --target <this id>"
}

output "bastion_private_ip" {
  value = aws_instance.bastion.private_ip
}

output "peering_connection_id" {
  value = aws_vpc_peering_connection.ops_to_cdp.id
}

output "session_command_hint" {
  value = "AWS_PROFILE=${var.ops_profile} AWS_REGION=${var.aws_region} aws ssm start-session --target ${aws_instance.bastion.id}"
}
