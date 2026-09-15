resource "aws_ssm_parameter" "vpc_id" {
  name  = "/oficina/${var.ambiente}/vpc-id"
  type  = "String"
  value = aws_vpc.oficina.id
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name        = "/oficina/${var.ambiente}/private-subnet-ids"
  description = "Lista separada por virgula, consumida por infra-db e pela Lambda"
  type        = "StringList"
  value       = join(",", [for s in aws_subnet.private : s.id])
}

resource "aws_ssm_parameter" "public_subnet_ids" {
  name  = "/oficina/${var.ambiente}/public-subnet-ids"
  type  = "StringList"
  value = join(",", [for s in aws_subnet.public : s.id])
}

resource "aws_ssm_parameter" "eks_cluster_name" {
  name  = "/oficina/${var.ambiente}/eks-cluster-name"
  type  = "String"
  value = aws_eks_cluster.oficina.name
}

resource "aws_ssm_parameter" "eks_node_security_group_id" {
  name        = "/oficina/${var.ambiente}/eks-node-security-group-id"
  description = "SG do cluster, referenciado pela regra de ingress do RDS"
  type        = "String"
  value       = aws_eks_cluster.oficina.vpc_config[0].cluster_security_group_id
}

resource "aws_ssm_parameter" "lambda_security_group_id" {
  name  = "/oficina/${var.ambiente}/lambda-security-group-id"
  type  = "String"
  value = aws_security_group.lambda.id
}

resource "aws_ssm_parameter" "nlb_dns" {
  name  = "/oficina/${var.ambiente}/nlb-dns"
  type  = "String"
  value = aws_lb.interno.dns_name
}

resource "aws_ssm_parameter" "api_gateway_id" {
  name  = "/oficina/${var.ambiente}/api-gateway-id"
  type  = "String"
  value = aws_apigatewayv2_api.oficina.id
}

resource "aws_ssm_parameter" "api_gateway_url" {
  name        = "/oficina/${var.ambiente}/api-gateway-url"
  description = "URL publica da API — e o link do deploy ativo da entrega"
  type        = "String"
  value       = local.api_url
}

