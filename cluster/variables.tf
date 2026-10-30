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
  description = "Tipos de instância dos nós. Em 2 nós t3.medium cabem 2 réplicas de cada serviço, a plataforma e a integração Kubernetes do New Relic."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Quantidade de nós em execução. O valor 3 acrescenta um nó caso os pods dos três serviços não caibam em 2."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= var.node_min_size && var.node_desired_size <= var.node_max_size
    error_message = "node_desired_size deve estar entre node_min_size e node_max_size."
  }
}

variable "node_min_size" {
  description = "Quantidade mínima de nós do node group."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Quantidade máxima de nós do node group."
  type        = number
  default     = 4
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

variable "ci_role_principal_arns" {
  description = "Roles dos pipelines dos serviços (OS, Billing e Execution), com permissão de edição só no namespace oficina."
  type        = list(string)
  default     = []
}

variable "servicos" {
  description = "Serviços publicados pelo NLB interno: NodePort fixo do Service no cluster e porta do listener (SPEC-08 §1)."
  type = map(object({
    node_port     = number
    listener_port = number
  }))
  default = {
    os        = { node_port = 30080, listener_port = 80 }
    billing   = { node_port = 30081, listener_port = 8081 }
    execution = { node_port = 30082, listener_port = 8082 }
  }

  validation {
    condition     = alltrue([for s in values(var.servicos) : s.node_port >= 30000 && s.node_port <= 32767])
    error_message = "node_port deve estar na faixa de NodePort do Kubernetes (30000-32767)."
  }
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

variable "newrelic_bundle_versao" {
  description = "Versão do chart nri-bundle (integração Kubernetes do New Relic: métricas de nós, pods e deployments)."
  type        = string
  default     = "8.0.24"
}
