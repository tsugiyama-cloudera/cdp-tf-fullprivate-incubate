# CDP Environment deployment (Phase 3). Prerequisites come from aws-init via remote state.

module "cdp_deploy" {
  source = "git::https://github.com/cloudera-labs/terraform-cdp-modules.git//modules/terraform-cdp-deploy?ref=v0.13.0"

  env_prefix          = var.env_prefix
  environment_type    = var.environment_type
  datalake_image      = var.datalake_image
  infra_type          = "aws"
  region              = var.aws_region
  keypair_name        = data.terraform_remote_state.init.outputs.aws_key_pair_name
  deployment_template = var.deployment_template
  datalake_scale      = var.datalake_scale
  datalake_version    = var.datalake_version
  enable_raz          = var.enable_raz
  datalake_recipes    = var.datalake_recipes
  freeipa_recipes     = var.freeipa_recipes
  cdp_groups          = local.cdp_groups

  compute_cluster_enabled       = var.compute_cluster_enabled
  compute_cluster_configuration = local.compute_cluster_configuration

  environment_async_creation = var.environment_async_creation
  datalake_async_creation    = var.datalake_async_creation

  freeipa_architecture  = var.freeipa_architecture
  datalake_architecture = var.datalake_architecture

  proxy_config_name = var.proxy_config_name

  aws_vpc_id             = data.terraform_remote_state.init.outputs.aws_vpc_id
  aws_public_subnet_ids  = data.terraform_remote_state.init.outputs.aws_public_subnet_ids
  aws_private_subnet_ids = data.terraform_remote_state.init.outputs.aws_private_subnet_ids

  aws_security_group_default_id = data.terraform_remote_state.init.outputs.aws_security_group_default_id
  aws_security_group_knox_id    = data.terraform_remote_state.init.outputs.aws_security_group_knox_id

  data_storage_location   = data.terraform_remote_state.init.outputs.aws_data_storage_location
  log_storage_location    = data.terraform_remote_state.init.outputs.aws_log_storage_location
  backup_storage_location = data.terraform_remote_state.init.outputs.aws_backup_storage_location

  aws_xaccount_role_arn       = data.terraform_remote_state.init.outputs.aws_xaccount_role_arn
  aws_datalake_admin_role_arn = data.terraform_remote_state.init.outputs.aws_datalake_admin_role_arn
  aws_ranger_audit_role_arn   = data.terraform_remote_state.init.outputs.aws_ranger_audit_role_arn
  aws_raz_role_arn            = data.terraform_remote_state.init.outputs.aws_datalake_admin_role_arn

  aws_log_instance_profile_arn      = data.terraform_remote_state.init.outputs.aws_log_instance_profile_arn
  aws_idbroker_instance_profile_arn = data.terraform_remote_state.init.outputs.aws_idbroker_instance_profile_arn

  env_tags = var.env_tags
}
