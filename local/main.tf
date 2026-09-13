terraform {
  required_version = ">= 1.5"
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.11"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "kind" {}

resource "kind_cluster" "oficina" {
  name            = var.cluster_name
  node_image      = var.node_image
  wait_for_ready  = true
  kubeconfig_path = "${path.module}/kubeconfig"
}

# ── Imagem da aplicação ────────────────────────────────────────────────────────

resource "null_resource" "build_and_load_image" {
  count      = var.build_local_image ? 1 : 0
  depends_on = [kind_cluster.oficina]

  triggers = {
    image      = var.app_image
    dockerfile = filesha1("${var.repo_root}/Dockerfile")
    pom        = filesha1("${var.repo_root}/pom.xml")
    src_hash   = sha1(join("", [for f in fileset("${var.repo_root}/src/main", "**") : filesha1("${var.repo_root}/src/main/${f}")]))
  }

  provisioner "local-exec" {
    command = "docker build -t ${var.app_image} ${var.repo_root} && kind load docker-image ${var.app_image} --name ${var.cluster_name}"
  }
}

# ── Segredos ───────────────────────────────────────────────────────────────────

resource "local_file" "db_secret" {
  content = templatefile("${path.module}/templates/db-secret.yaml.tftpl", {
    db_username = var.db_username
    db_password = var.db_password
  })
  filename = "${path.module}/rendered/db-secret.yaml"
}

resource "local_file" "app_secret" {
  content = templatefile("${path.module}/templates/app-secret.yaml.tftpl", {
    db_username    = var.db_username
    db_password    = var.db_password
    jwt_secret     = var.jwt_secret
    admin_password = var.admin_password
  })
  filename = "${path.module}/rendered/app-secret.yaml"
}

# ── Deploy ─────────────────────────────────────────────────────────────────────

resource "null_resource" "deploy_app" {
  depends_on = [
    kind_cluster.oficina,
    null_resource.build_and_load_image,
    local_file.db_secret,
    local_file.app_secret,
  ]

  triggers = {
    image          = var.app_image
    db_secret      = local_file.db_secret.content_md5
    app_secret     = local_file.app_secret.content_md5
    manifests_hash = sha1(join("", [for f in fileset(var.k8s_manifests_path, "**/*.yaml") : filesha1("${var.k8s_manifests_path}/${f}")]))
  }

  provisioner "local-exec" {
    command = join(" && ", [
      "kubectl --kubeconfig=${kind_cluster.oficina.kubeconfig_path} apply -f ${var.k8s_manifests_path}/namespace.yaml",
      "kubectl --kubeconfig=${kind_cluster.oficina.kubeconfig_path} apply -f ${var.k8s_manifests_path}/metrics-server/",
      "kubectl --kubeconfig=${kind_cluster.oficina.kubeconfig_path} patch deployment metrics-server -n kube-system --type=json --patch-file=${path.module}/metrics-server-kind-patch.json",
      "kubectl --kubeconfig=${kind_cluster.oficina.kubeconfig_path} apply -f ${local_file.db_secret.filename}",
      "kubectl --kubeconfig=${kind_cluster.oficina.kubeconfig_path} apply -f ${var.k8s_manifests_path}/database/configmap.yaml -f ${var.k8s_manifests_path}/database/service.yaml -f ${var.k8s_manifests_path}/database/statefulset.yaml",
      "kubectl --kubeconfig=${kind_cluster.oficina.kubeconfig_path} apply -f ${var.k8s_manifests_path}/mailhog/",
      "kubectl --kubeconfig=${kind_cluster.oficina.kubeconfig_path} apply -f ${local_file.app_secret.filename}",
      "kubectl --kubeconfig=${kind_cluster.oficina.kubeconfig_path} apply -f ${var.k8s_manifests_path}/app/configmap.yaml -f ${var.k8s_manifests_path}/app/deployment.yaml -f ${var.k8s_manifests_path}/app/service.yaml -f ${var.k8s_manifests_path}/app/hpa.yaml",
      "kubectl --kubeconfig=${kind_cluster.oficina.kubeconfig_path} set image deployment/oficina-api oficina-api=${var.app_image} -n oficina",
    ])
  }
}
