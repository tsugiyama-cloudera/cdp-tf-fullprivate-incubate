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

locals {
  cdp_private_route_table_ids = coalesce(
    var.peer_private_route_table_ids,
    data.terraform_remote_state.init.outputs.aws_private_route_table_ids
  )
}
