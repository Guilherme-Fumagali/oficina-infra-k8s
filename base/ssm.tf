resource "aws_ssm_parameter" "ecr_repository_url" {
  name  = "/oficina/${var.ambiente}/ecr-repository-url"
  type  = "String"
  value = aws_ecr_repository.oficina_api.repository_url
}

resource "aws_ssm_parameter" "jwt_secret" {
  name  = "/oficina/${var.ambiente}/jwt-secret"
  type  = "SecureString"
  value = var.jwt_secret
}

resource "aws_ssm_parameter" "newrelic_license_key" {
  count = var.newrelic_license_key == "" ? 0 : 1

  name  = "/oficina/${var.ambiente}/newrelic-license-key"
  type  = "SecureString"
  value = var.newrelic_license_key
}
