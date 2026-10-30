data "aws_ssm_parameter" "newrelic_license_key" {
  count           = var.enable_newrelic ? 1 : 0
  name            = "/oficina/${var.ambiente}/newrelic-license-key"
  with_decryption = true
}

locals {
  manifests_dir = "${path.module}/k8s"

  manifests_plataforma = concat(
    ["namespace.yaml"],
    tolist(fileset(local.manifests_dir, "metrics-server/*.yaml")),
    tolist(fileset(local.manifests_dir, "mailhog/*.yaml")),
  )

  manifests_sha = sha256(join("", [
    for arquivo in sort(local.manifests_plataforma) : filesha256("${local.manifests_dir}/${arquivo}")
  ]))
}

resource "null_resource" "manifests_plataforma" {
  triggers = {
    cluster       = aws_eks_cluster.oficina.name
    manifests_sha = local.manifests_sha
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name ${aws_eks_cluster.oficina.name} --region ${var.aws_region}

      kubectl apply -f ${local.manifests_dir}/namespace.yaml
      kubectl apply -f ${local.manifests_dir}/metrics-server/components.yaml
      kubectl apply -f ${local.manifests_dir}/mailhog/
    EOT
  }

  depends_on = [aws_eks_node_group.oficina]
}

resource "null_resource" "newrelic_kubernetes" {
  count = var.enable_newrelic ? 1 : 0

  triggers = {
    cluster     = aws_eks_cluster.oficina.name
    chart       = var.newrelic_bundle_versao
    values_sha  = filesha256("${path.module}/k8s/newrelic/values.yaml")
    license_sha = sha256(data.aws_ssm_parameter.newrelic_license_key[0].value)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name ${aws_eks_cluster.oficina.name} --region ${var.aws_region}
      NEW_RELIC_LICENSE_KEY=$(aws ssm get-parameter --name ${data.aws_ssm_parameter.newrelic_license_key[0].name} \
        --with-decryption --query Parameter.Value --output text --region ${var.aws_region})

      helm repo add newrelic https://helm-charts.newrelic.com --force-update
      helm upgrade --install newrelic-bundle newrelic/nri-bundle \
        --version ${var.newrelic_bundle_versao} \
        --namespace newrelic --create-namespace \
        -f ${path.module}/k8s/newrelic/values.yaml \
        --set global.licenseKey="$NEW_RELIC_LICENSE_KEY" \
        --set global.cluster=${aws_eks_cluster.oficina.name} \
        --wait --timeout 10m
    EOT
  }

  depends_on = [null_resource.manifests_plataforma]
}
