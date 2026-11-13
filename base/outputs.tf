output "ecr_repository_urls" {
  value = { for chave, repositorio in aws_ecr_repository.servico : chave => repositorio.repository_url }
}
