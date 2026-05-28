# Reads Phase-1 outputs from aws-init (local state by default).

variable "init_state_path" {
  type        = string
  description = "Path to aws-init terraform.tfstate"
  default     = "../aws-init/terraform.tfstate"
}

data "terraform_remote_state" "init" {
  backend = "local"

  config = {
    path = var.init_state_path
  }
}
