output "instance_id" {
  value = aws_instance.host.id
}

output "public_ip" {
  description = "Egress-only address. Used by scripts/validate.sh to prove nothing listens publicly."
  value       = aws_instance.host.public_ip
}

output "security_group_id" {
  value = aws_security_group.host.id
}

output "table_urls" {
  description = "Tailnet-only HTTPS URLs for each tabletop."
  value       = local.table_url
}

output "ssh_command" {
  value = "tailscale ssh ubuntu@${local.host_name}"
}

output "break_glass" {
  description = "If Tailscale SSH is unavailable, SSM Session Manager works without any inbound port."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.host.id}"
}
