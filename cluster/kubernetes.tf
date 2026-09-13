data "aws_ssm_parameter" "ecr_repository_url" {
  name = "/oficina/${var.ambiente}/ecr-repository-url"
}

data "aws_ssm_parameter" "jwt_secret" {
  count           = var.aplicar_manifests ? 1 : 0
  name            = "/oficina/${var.ambiente}/jwt-secret"
  with_decryption = true
}

data "aws_ssm_parameter" "newrelic_license_key" {
  count           = var.aplicar_manifests && var.enable_newrelic ? 1 : 0
  name            = "/oficina/${var.ambiente}/newrelic-license-key"
  with_decryption = true
}

data "aws_ssm_parameter" "db_endpoint" {
  count = var.aplicar_manifests ? 1 : 0
  name  = "/oficina/${var.ambiente}/db-endpoint"
}

data "aws_ssm_parameter" "db_name" {
  count = var.aplicar_manifests ? 1 : 0
  name  = "/oficina/${var.ambiente}/db-name"
}

data "aws_ssm_parameter" "db_username" {
  count = var.aplicar_manifests ? 1 : 0
  name  = "/oficina/${var.ambiente}/db-username"
}

data "aws_ssm_parameter" "db_password" {
  count           = var.aplicar_manifests ? 1 : 0
  name            = "/oficina/${var.ambiente}/db-password"
  with_decryption = true
}

locals {
  manifests_dir = "${path.module}/k8s"

  db_url = var.aplicar_manifests ? format(
    "jdbc:postgresql://%s/%s",
    data.aws_ssm_parameter.db_endpoint[0].value,
    data.aws_ssm_parameter.db_name[0].value,
  ) : ""
}

resource "local_file" "app_configmap" {
  count = var.aplicar_manifests ? 1 : 0

  filename        = "${local.manifests_dir}/app/configmap.generated.yaml"
  file_permission = "0644"

  content = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "oficina-api-config"
      namespace = "oficina"
    }
    data = {
      PORT                                = "8080"
      SPRING_PROFILES_ACTIVE              = "k8s"
      ENV                                 = var.ambiente
      DB_URL                              = local.db_url
      NOTIFICACAO_CANAL                   = "smtp"
      SMTP_HOST                           = "oficina-mailhog"
      SMTP_PORT                           = "1025"
      MAIL_FROM                           = "oficina@example.com"
      MAIL_BASE_URL                       = aws_apigatewayv2_stage.principal.invoke_url
      MANAGEMENT_TRACING_ENABLED          = "true"
      OTEL_EXPORTER_OTLP_METRICS_ENDPOINT = "https://otlp.nr-data.net/v1/metrics"
      METRICS_EXPORT_STEP                 = "60s"
    }
  })
}

resource "local_file" "app_secret" {
  count = var.aplicar_manifests ? 1 : 0

  filename        = "${local.manifests_dir}/app/secret.generated.yaml"
  file_permission = "0600"

  content = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "oficina-api-secret"
      namespace = "oficina"
    }
    type = "Opaque"
    stringData = {
      DB_USER               = data.aws_ssm_parameter.db_username[0].value
      DB_PASS               = data.aws_ssm_parameter.db_password[0].value
      JWT_SECRET            = data.aws_ssm_parameter.jwt_secret[0].value
      NEW_RELIC_LICENSE_KEY = var.enable_newrelic ? data.aws_ssm_parameter.newrelic_license_key[0].value : ""
    }
  })
}

resource "null_resource" "aplicar_manifests" {
  count = var.aplicar_manifests ? 1 : 0

  triggers = {
    configmap  = local_file.app_configmap[0].content
    secret_sha = sha256(local_file.app_secret[0].content)
    imagem     = data.aws_ssm_parameter.ecr_repository_url.value
    cluster    = aws_eks_cluster.oficina.name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name ${aws_eks_cluster.oficina.name} --region ${var.aws_region}

      kubectl apply -f ${local.manifests_dir}/namespace.yaml
      kubectl apply -f ${local.manifests_dir}/metrics-server/components.yaml
      kubectl apply -f ${local_file.app_configmap[0].filename}
      kubectl apply -f ${local_file.app_secret[0].filename}

      sed 's|ECR_REPOSITORY_URL|${data.aws_ssm_parameter.ecr_repository_url.value}|' \
        ${local.manifests_dir}/app/deployment.yaml | kubectl apply -f -

      kubectl apply -f ${local.manifests_dir}/app/service.yaml
      kubectl apply -f ${local.manifests_dir}/app/hpa.yaml
    EOT
  }

  depends_on = [aws_eks_node_group.oficina]
}
