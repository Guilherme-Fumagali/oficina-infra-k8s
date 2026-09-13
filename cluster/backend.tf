terraform {
  backend "s3" {
    bucket         = "oficina-api-tfstate-002754693932-us-east-1-an"
    key            = "infra-k8s/cluster/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "oficina-api-tfstate-lock"
    encrypt        = true
  }
}
