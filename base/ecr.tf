resource "aws_ecr_repository" "oficina_api" {
  name                 = "oficina-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "oficina_api" {
  repository = aws_ecr_repository.oficina_api.name

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
