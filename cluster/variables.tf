variable "aws_region" {
  description = "Região da AWS. Trocar exige revisar as chaves de AZ em subnet_cidrs."
  type        = string
  default     = "us-east-1"
}

variable "ambiente" {
  description = "Ambiente lógico (staging ou prod)."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["staging", "prod"], var.ambiente)
    error_message = "ambiente deve ser staging ou prod."
  }
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes no EKS."
  type        = string
  default     = "1.36"
}

variable "node_instance_types" {
  description = "Tipos de instância dos nós. t3.small = menor custo com folga para kubelet + aplicação."
  type        = list(string)
  default     = ["t3.small"]
}

variable "vpc_cidr" {
  description = "CIDR da VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Subnets públicas por AZ. Hospedam apenas a NAT instance."
  type        = map(string)
  default = {
    "us-east-1a" = "10.0.1.0/24"
    "us-east-1b" = "10.0.2.0/24"
  }
}

variable "private_subnet_cidrs" {
  description = "Subnets privadas por AZ. Hospedam nós do EKS, RDS, Lambda e o NLB interno."
  type        = map(string)
  default = {
    "us-east-1a" = "10.0.11.0/24"
    "us-east-1b" = "10.0.12.0/24"
  }
}

variable "nat_instance_type" {
  description = "Tipo da NAT instance. t4g.nano custa ~US$3/mês contra ~US$33 do NAT Gateway (ADR-007)."
  type        = string
  default     = "t4g.nano"
}

variable "cluster_admin_principal_arn" {
  description = "Principal IAM com acesso admin ao cluster (kubectl local)."
  type        = string
  default     = ""
}

variable "ci_role_principal_arn" {
  description = "Role da pipeline do oficina-api, com permissão de edição só no namespace oficina."
  type        = string
  default     = ""
}

variable "app_node_port" {
  description = "NodePort fixo do Service da aplicação, alvo do target group do NLB."
  type        = number
  default     = 30080
}

variable "enable_lambda_routes" {
  description = <<-EOT
    Liga as rotas do API Gateway que apontam para a Lambda.

    Fica false no primeiro apply porque há dependência circular: o gateway precisa
    do ARN da função, e a função precisa da rede criada aqui. Vira true depois que
    o repositório oficina-auth-lambda publica os ARNs no SSM (SPEC-05 §5).
  EOT
  type        = bool
  default     = false
}

variable "enable_newrelic" {
  description = "Cria dashboards, alertas e monitor sintético. Exige chaves válidas."
  type        = bool
  default     = false
}

variable "newrelic_account_id" {
  description = "ID da conta New Relic."
  type        = string
  default     = "0"
}

variable "newrelic_api_key" {
  description = "User API key do New Relic (NRAK-...)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "alerta_email" {
  description = "Destinatário das notificações de alerta."
  type        = string
  default     = ""
}

variable "aplicar_manifests" {
  description = <<-EOT
    Aplica os manifests do Kubernetes no cluster ao final do apply.

    Fica false quando o RDS ainda não existe (primeiro apply), porque o ConfigMap
    precisa do endpoint do banco publicado por oficina-infra-db (SPEC-05 §6).
  EOT
  type        = bool
  default     = false
}
