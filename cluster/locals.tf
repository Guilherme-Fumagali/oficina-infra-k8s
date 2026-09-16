locals {
  nome = "oficina-api-${var.ambiente}"

  api_url = trimsuffix(aws_apigatewayv2_stage.principal.invoke_url, "/")
}
