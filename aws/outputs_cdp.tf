output "cdp_environment_name" {
  value       = module.cdp_deploy.cdp_environment_name
  description = "CDP Environment Name"
}

output "cdp_environment_crn" {
  value       = module.cdp_deploy.cdp_environment_crn
  description = "CDP Environment CRN"
}
