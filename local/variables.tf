variable "cluster_name" {
  description = "Nome do cluster kind"
  type        = string
  default     = "oficina-local"
}

variable "node_image" {
  description = "Imagem do nó kind. Precisa ser compatível com a versão do binário kind instalado."
  type        = string
  default     = "kindest/node:v1.31.0"
}

variable "repo_root" {
  description = "Raiz do repositório, relativa a este módulo (contexto do docker build)"
  type        = string
  default     = "../../.."
}

variable "k8s_manifests_path" {
  description = "Caminho para os manifests Kubernetes, relativo a este módulo"
  type        = string
  default     = "../../../k8s"
}

variable "app_image" {
  description = <<-EOT
    Imagem da API a implantar no cluster. O padrão é uma tag local, construída e carregada
    no kind por este próprio módulo (ver build_local_image) — assim o apply não depende de
    registry nem de credencial. Para usar a imagem publicada pelo CI, aponte para
    ghcr.io/<owner>/oficina-api:latest e desligue build_local_image (o pacote no GHCR
    precisa estar público, senão o nó não consegue dar pull).
  EOT
  type        = string
  default     = "oficina-api:local"
}

variable "build_local_image" {
  description = "Se true, roda docker build + kind load antes do deploy, usando a tag em app_image."
  type        = bool
  default     = true
}

variable "db_username" {
  description = "Usuário do Postgres in-cluster"
  type        = string
  default     = "oficina"
}

variable "db_password" {
  description = "Senha do Postgres in-cluster"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "Chave de assinatura HS256 — mínimo 32 caracteres, senão a aplicação não sobe"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.jwt_secret) >= 32
    error_message = "jwt_secret precisa ter ao menos 32 caracteres (exigência do HS256)."
  }
}

variable "admin_password" {
  description = "Senha do usuário administrador criado no bootstrap da aplicação"
  type        = string
  sensitive   = true
}
