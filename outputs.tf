output "jump_public_ip" {
  description = "Public IP of the only publicly reachable VM."
  value       = azurerm_public_ip.jump.ip_address
}

output "generated_private_key_pem" {
  description = "Temporary SSH private key, only populated when ssh_public_key is not supplied. Sensitive; stored in Terraform state."
  value       = trimspace(var.ssh_public_key) == "" ? tls_private_key.generated[0].private_key_pem : null
  sensitive   = true
}

output "developer_internal_load_balancers" {
  description = "Internal Moodle Load Balancer IP per developer."
  value = {
    for key, dev in local.developers : key => azurerm_lb.developer[key].frontend_ip_configuration[0].private_ip_address
  }
}

output "app_private_ips" {
  description = "Private IPs for app VMs."
  value = {
    for key, nic in azurerm_network_interface.app : key => nic.private_ip_address
  }
}

output "resource_groups" {
  description = "Resource groups to delete after testing."
  value = concat(
    [azurerm_resource_group.core.name],
    [for rg in azurerm_resource_group.developer : rg.name]
  )
}
