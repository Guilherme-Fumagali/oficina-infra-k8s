output "cluster_name" {
  description = "Nome do cluster kind criado"
  value       = kind_cluster.oficina.name
}

output "kubeconfig_path" {
  description = "Caminho do kubeconfig gerado para o cluster"
  value       = kind_cluster.oficina.kubeconfig_path
}

output "app_image" {
  description = "Imagem implantada no cluster"
  value       = var.app_image
}

output "acesso" {
  description = "Como falar com a API depois do apply"
  value       = "kubectl --kubeconfig=${kind_cluster.oficina.kubeconfig_path} port-forward svc/oficina-api 8080:80 -n oficina"
}
