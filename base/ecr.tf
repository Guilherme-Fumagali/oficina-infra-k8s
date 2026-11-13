locals {
  servicos = {
    os        = "os-service"
    billing   = "billing-service"
    execution = "execution-service"
  }
}

resource "aws_ecr_repository" "servico" {
  for_each = local.servicos

  name                 = "oficina-${each.value}-${var.ambiente}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "servico" {
  for_each = aws_ecr_repository.servico

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Manter as 10 imagens mais recentes"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
