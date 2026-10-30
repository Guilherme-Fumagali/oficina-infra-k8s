resource "aws_ssm_parameter" "ecr_repository_url" {
  for_each = aws_ecr_repository.servico

  name  = "/oficina/${var.ambiente}/${each.key}/ecr-repository-url"
  type  = "String"
  value = each.value.repository_url
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "jwt_secret" {
  name  = "/oficina/${var.ambiente}/jwt-secret"
  type  = "SecureString"
  value = random_password.jwt_secret.result
}

resource "aws_ssm_parameter" "newrelic_license_key" {
  count = var.newrelic_license_key == "" ? 0 : 1

  name  = "/oficina/${var.ambiente}/newrelic-license-key"
  type  = "SecureString"
  value = var.newrelic_license_key
}
