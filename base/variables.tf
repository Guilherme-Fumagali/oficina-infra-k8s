variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "ambiente" {
  type    = string
  default = "prod"

  validation {
    condition     = contains(["staging", "prod"], var.ambiente)
    error_message = "ambiente deve ser staging ou prod."
  }
}

variable "jwt_secret" {
  type      = string
  sensitive = true
}

variable "newrelic_license_key" {
  type      = string
  sensitive = true
  default   = ""
}
