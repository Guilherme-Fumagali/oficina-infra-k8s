terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Projeto   = "oficina-api"
      Fase      = "tech-challenge-3"
      Ambiente  = var.ambiente
      ManagedBy = "terraform"
      Repo      = "oficina-infra-k8s"
    }
  }
}
