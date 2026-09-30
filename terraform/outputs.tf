# nothing sensitive here, just what DEPLOY.md needs

output "region" {
  value = local.region
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "tunnel_host_id" {
  value = aws_instance.admin_host.id
}

output "human_role_arns" {
  value = { for k, r in aws_iam_role.human : k => r.arn }
}

output "app_secret_reader_role_arn" {
  description = "Goes on the secret-reader service account annotation"
  value       = aws_iam_role.app_secret_reader.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.app.name
}

output "ecr_registry" {
  value = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "subnet_cidrs" {
  description = "Used by the kubernetes network policies"
  value       = local.subnet_cidrs
}
