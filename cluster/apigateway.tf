resource "aws_lb" "interno" {
  name               = "oficina-api-nlb-${var.ambiente}"
  internal           = true
  load_balancer_type = "network"
  subnets            = [for s in aws_subnet.private : s.id]

  enable_cross_zone_load_balancing = true

  tags = { Name = "oficina-api-nlb-${var.ambiente}" }
}

resource "aws_lb_target_group" "app" {
  name        = "oficina-api-tg-${var.ambiente}"
  port        = var.app_node_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.oficina.id

  health_check {
    protocol            = "HTTP"
    path                = "/actuator/health"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 15
  }

  deregistration_delay = 30
}

resource "aws_autoscaling_attachment" "nodes" {
  autoscaling_group_name = aws_eks_node_group.oficina.resources[0].autoscaling_groups[0].name
  lb_target_group_arn    = aws_lb_target_group.app.arn
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.interno.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_vpc_security_group_ingress_rule" "nodeport_do_nlb" {
  for_each = var.private_subnet_cidrs

  security_group_id = aws_eks_cluster.oficina.vpc_config[0].cluster_security_group_id
  description       = "NodePort a partir do NLB interno (${each.key})"
  cidr_ipv4         = each.value
  from_port         = var.app_node_port
  to_port           = var.app_node_port
  ip_protocol       = "tcp"
}

resource "aws_security_group" "vpc_link" {
  name        = "${local.nome}-vpclink-sg"
  description = "VPC Link do API Gateway ate o NLB interno"
  vpc_id      = aws_vpc.oficina.id

  tags = { Name = "${local.nome}-vpclink-sg" }
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_saida" {
  security_group_id = aws_security_group.vpc_link.id
  description       = "Saida para o NLB"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_apigatewayv2_vpc_link" "oficina" {
  name               = "oficina-api-vpclink-${var.ambiente}"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = [for s in aws_subnet.private : s.id]
}

resource "aws_apigatewayv2_api" "oficina" {
  name          = "oficina-api-${var.ambiente}"
  protocol_type = "HTTP"
  description   = "Borda unica da oficina: autenticacao por CPF e APIs protegidas"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type"]
    max_age       = 300
  }
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/oficina-api-${var.ambiente}"
  retention_in_days = 7
}

resource "aws_apigatewayv2_stage" "principal" {
  api_id      = aws_apigatewayv2_api.oficina.id
  name        = var.ambiente
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = 100
    throttling_burst_limit = 200
  }

  dynamic "route_settings" {
    for_each = var.enable_lambda_routes ? ["POST /auth", "POST /auth/funcionarios"] : []
    content {
      route_key              = route_settings.value
      throttling_rate_limit  = 10
      throttling_burst_limit = 20
    }
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn

    format = jsonencode({
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      requestTime        = "$context.requestTime"
      routeKey           = "$context.routeKey"
      status             = "$context.status"
      responseLatency    = "$context.responseLatency"
      integrationLatency = "$context.integrationLatency"
      errorMessage       = "$context.error.message"
    })
  }

  depends_on = [
    aws_apigatewayv2_route.auth,
    aws_apigatewayv2_route.auth_funcionarios,
  ]
}

resource "aws_apigatewayv2_integration" "cluster" {
  api_id             = aws_apigatewayv2_api.oficina.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = aws_lb_listener.app.arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.oficina.id

  payload_format_version = "1.0"
}

data "aws_ssm_parameter" "auth_lambda_arn" {
  count = var.enable_lambda_routes ? 1 : 0
  name  = "/oficina/${var.ambiente}/auth-lambda-arn"
}

data "aws_ssm_parameter" "authorizer_lambda_arn" {
  count = var.enable_lambda_routes ? 1 : 0
  name  = "/oficina/${var.ambiente}/authorizer-lambda-arn"
}

resource "aws_apigatewayv2_integration" "auth" {
  count = var.enable_lambda_routes ? 1 : 0

  api_id                 = aws_apigatewayv2_api.oficina.id
  integration_type       = "AWS_PROXY"
  integration_uri        = data.aws_ssm_parameter.auth_lambda_arn[0].insecure_value
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  count = var.enable_lambda_routes ? 1 : 0

  api_id                            = aws_apigatewayv2_api.oficina.id
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${data.aws_ssm_parameter.authorizer_lambda_arn[0].insecure_value}/invocations"
  identity_sources                  = ["$request.header.Authorization"]
  name                              = "oficina-jwt-authorizer"
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true

  authorizer_result_ttl_in_seconds = 300
}

resource "aws_lambda_permission" "auth" {
  count = var.enable_lambda_routes ? 1 : 0

  statement_id  = "AllowAPIGatewayInvokeAuth"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_ssm_parameter.auth_lambda_arn[0].insecure_value
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.oficina.execution_arn}/*/*"
}

resource "aws_lambda_permission" "authorizer" {
  count = var.enable_lambda_routes ? 1 : 0

  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_ssm_parameter.authorizer_lambda_arn[0].insecure_value
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.oficina.execution_arn}/*"
}

resource "aws_apigatewayv2_route" "auth" {
  count = var.enable_lambda_routes ? 1 : 0

  api_id    = aws_apigatewayv2_api.oficina.id
  route_key = "POST /auth"
  target    = "integrations/${aws_apigatewayv2_integration.auth[0].id}"
}

resource "aws_apigatewayv2_route" "auth_funcionarios" {
  count = var.enable_lambda_routes ? 1 : 0

  api_id    = aws_apigatewayv2_api.oficina.id
  route_key = "POST /auth/funcionarios"
  target    = "integrations/${aws_apigatewayv2_integration.auth[0].id}"
}

locals {
  rotas_publicas = [
    "GET /api/ordens/{id}/status",
    "POST /api/ordens/{id}/aprovar-externo",
    "GET /api/ordens/{id}/aprovar-externo",
    "GET /api/ordens/{id}/reprovar-externo",
    "GET /actuator/health",
  ]
}

resource "aws_apigatewayv2_route" "publicas" {
  for_each = toset(local.rotas_publicas)

  api_id    = aws_apigatewayv2_api.oficina.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.cluster.id}"
}

resource "aws_apigatewayv2_route" "protegidas" {
  api_id    = aws_apigatewayv2_api.oficina.id
  route_key = "ANY /api/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.cluster.id}"

  authorization_type = var.enable_lambda_routes ? "CUSTOM" : "NONE"
  authorizer_id      = var.enable_lambda_routes ? aws_apigatewayv2_authorizer.jwt[0].id : null
}
