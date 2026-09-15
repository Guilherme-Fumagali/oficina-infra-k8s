output "api_gateway_url" {
  description = "URL publica da API — link do deploy ativo para a entrega."
  value       = local.api_url
}

output "eks_cluster_name" {
  value = aws_eks_cluster.oficina.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.oficina.endpoint
}

output "ecr_repository_url" {
  value = data.aws_ssm_parameter.ecr_repository_url.insecure_value
}

output "nlb_dns_name" {
  description = "DNS interno do NLB. Nao deve ser alcancavel da internet."
  value       = aws_lb.interno.dns_name
}

output "nat_public_ip" {
  description = "IP de saida da VPC — util para liberar em allowlist de terceiros."
  value       = aws_eip.nat.public_ip
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "lambda_security_group_id" {
  value = aws_security_group.lambda.id
}
