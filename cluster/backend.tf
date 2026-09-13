terraform {
  backend "s3" {
    bucket         = "oficina-api-tfstate-002754693932-us-east-1-an"
    region         = "us-east-1"
    dynamodb_table = "oficina-api-tfstate-lock"
    encrypt        = true
  }
}
