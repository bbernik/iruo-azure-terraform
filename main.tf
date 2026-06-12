data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  numeric = true
  special = false
  upper   = false
}

resource "tls_private_key" "generated" {
  count = trimspace(var.ssh_public_key) == "" ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 4096
}

locals {
  tags = {
    project     = var.project
    environment = var.environment
  }

  ssh_public_key = trimspace(var.ssh_public_key) != "" ? var.ssh_public_key : tls_private_key.generated[0].public_key_openssh

  csv_lines = [
    for line in split("\n", replace(file(var.users_csv_path), "\r\n", "\n")) :
    trimspace(line)
    if trimspace(line) != "" && !startswith(trimspace(line), "#")
  ]

  csv_rows = [
    for line in slice(local.csv_lines, 1, length(local.csv_lines)) : split(";", line)
  ]

  users = [
    for row in local.csv_rows : {
      ime                 = lower(trimspace(row[0]))
      prezime             = lower(trimspace(row[1]))
      rola                = lower(trimspace(row[2]))
      principal_object_id = length(row) > 3 ? trimspace(row[3]) : ""
      key                 = "${lower(trimspace(row[0]))}-${lower(trimspace(row[1]))}"
    }
  ]

  developers = {
    for idx, user in [for u in local.users : u if u.rola == "developer"] :
    user.key => merge(user, {
      index     = idx
      vnet_cidr = "10.${var.developer_vnet_base_octet + idx}.0.0/16"
      app_cidr  = "10.${var.developer_vnet_base_octet + idx}.1.0/24"
      lb_ip     = "10.${var.developer_vnet_base_octet + idx}.1.10"
    })
  }

  leads = {
    for user in local.users : user.key => user
    if user.rola == "devops_lead"
  }

  app_instances = merge([
    for dev_key, dev in local.developers : {
      for instance_number in [1, 2] : "${dev_key}-app${instance_number}" => {
        dev_key         = dev_key
        instance_number = instance_number
        name            = "vm-${var.project}-${dev.ime}${dev.prezime}-app${instance_number}"
        storage_key     = dev_key
      }
    }
  ]...)

  developer_principals = {
    for key, user in local.developers : key => user
    if user.principal_object_id != ""
  }

  lead_principals = {
    for key, user in local.leads : key => user
    if user.principal_object_id != ""
  }
}

resource "azurerm_resource_group" "core" {
  name     = "rg-${var.project}-${var.environment}-core"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "developer" {
  for_each = local.developers

  name     = "rg-${var.project}-${var.environment}-${each.value.ime}${each.value.prezime}"
  location = var.location
  tags     = merge(local.tags, { owner = each.key })
}

resource "azurerm_virtual_network" "lead" {
  name                = "vnet-${var.project}-${var.environment}-lead"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  address_space       = [var.lead_vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "jump" {
  name                 = "snet-jump"
  resource_group_name  = azurerm_resource_group.core.name
  virtual_network_name = azurerm_virtual_network.lead.name
  address_prefixes     = [cidrsubnet(var.lead_vnet_cidr, 8, 1)]
}

resource "azurerm_virtual_network" "developer" {
  for_each = local.developers

  name                = "vnet-${var.project}-${var.environment}-${each.value.ime}${each.value.prezime}"
  location            = azurerm_resource_group.developer[each.key].location
  resource_group_name = azurerm_resource_group.developer[each.key].name
  address_space       = [each.value.vnet_cidr]
  tags                = merge(local.tags, { owner = each.key })
}

resource "azurerm_subnet" "app" {
  for_each = local.developers

  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.developer[each.key].name
  virtual_network_name = azurerm_virtual_network.developer[each.key].name
  address_prefixes     = [each.value.app_cidr]
}

resource "azurerm_virtual_network_peering" "lead_to_dev" {
  for_each = local.developers

  name                      = "peer-lead-to-${each.value.ime}${each.value.prezime}"
  resource_group_name       = azurerm_resource_group.core.name
  virtual_network_name      = azurerm_virtual_network.lead.name
  remote_virtual_network_id = azurerm_virtual_network.developer[each.key].id
  allow_forwarded_traffic   = false
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

resource "azurerm_virtual_network_peering" "dev_to_lead" {
  for_each = local.developers

  name                      = "peer-${each.value.ime}${each.value.prezime}-to-lead"
  resource_group_name       = azurerm_resource_group.developer[each.key].name
  virtual_network_name      = azurerm_virtual_network.developer[each.key].name
  remote_virtual_network_id = azurerm_virtual_network.lead.id
  allow_forwarded_traffic   = false
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

resource "azurerm_network_security_group" "jump" {
  name                = "nsg-${var.project}-${var.environment}-jump"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  tags                = local.tags

  security_rule {
    name                       = "Allow-SSH-From-Allowed-CIDR"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "app" {
  for_each = local.developers

  name                = "nsg-${var.project}-${var.environment}-${each.value.ime}${each.value.prezime}-app"
  location            = azurerm_resource_group.developer[each.key].location
  resource_group_name = azurerm_resource_group.developer[each.key].name
  tags                = merge(local.tags, { owner = each.key })

  security_rule {
    name                       = "Allow-SSH-From-Lead-VNet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.lead_vnet_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-HTTP-From-Lead-And-Own-VNet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefixes    = [var.lead_vnet_cidr, each.value.vnet_cidr]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Azure-LB-Probe"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "jump" {
  subnet_id                 = azurerm_subnet.jump.id
  network_security_group_id = azurerm_network_security_group.jump.id
}

resource "azurerm_subnet_network_security_group_association" "app" {
  for_each = local.developers

  subnet_id                 = azurerm_subnet.app[each.key].id
  network_security_group_id = azurerm_network_security_group.app[each.key].id
}

resource "azurerm_application_security_group" "app" {
  for_each = local.developers

  name                = "asg-${var.project}-${var.environment}-${each.value.ime}${each.value.prezime}-moodle"
  location            = azurerm_resource_group.developer[each.key].location
  resource_group_name = azurerm_resource_group.developer[each.key].name
  tags                = merge(local.tags, { owner = each.key })
}

resource "azurerm_public_ip" "jump" {
  name                = "pip-${var.project}-${var.environment}-jump"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "jump" {
  name                = "nic-${var.project}-${var.environment}-jump"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.jump.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jump.id
  }
}

resource "azurerm_linux_virtual_machine" "jump" {
  name                = "vm-${var.project}-${var.environment}-jump"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  size                = var.jump_vm_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.jump.id
  ]
  tags = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.ssh_public_key
  }

  os_disk {
    name                 = "disk-${var.project}-${var.environment}-jump-os"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init-jump.yaml.tpl", {
    admin_username = var.admin_username
  }))
}

resource "azurerm_storage_account" "developer" {
  for_each = local.developers

  name                            = substr(replace("st${var.project}${each.value.ime}${random_string.suffix.result}", "-", ""), 0, 24)
  location                        = azurerm_resource_group.developer[each.key].location
  resource_group_name             = azurerm_resource_group.developer[each.key].name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  access_tier                     = "Hot"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  tags                            = merge(local.tags, { owner = each.key })
}

resource "azurerm_storage_container" "moodle" {
  for_each = local.developers

  name                  = "moodle-objects"
  storage_account_name  = azurerm_storage_account.developer[each.key].name
  container_access_type = "private"
}

resource "azurerm_storage_share" "backups" {
  for_each = local.developers

  name                 = "moodle-backups"
  storage_account_name = azurerm_storage_account.developer[each.key].name
  quota                = 50
}

resource "azurerm_lb" "developer" {
  for_each = local.developers

  name                = "lb-${var.project}-${var.environment}-${each.value.ime}${each.value.prezime}"
  location            = azurerm_resource_group.developer[each.key].location
  resource_group_name = azurerm_resource_group.developer[each.key].name
  sku                 = "Standard"
  tags                = merge(local.tags, { owner = each.key })

  frontend_ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app[each.key].id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.lb_ip
  }
}

resource "azurerm_lb_backend_address_pool" "developer" {
  for_each = local.developers

  name            = "pool-moodle"
  loadbalancer_id = azurerm_lb.developer[each.key].id
}

resource "azurerm_lb_probe" "developer" {
  for_each = local.developers

  name            = "probe-http"
  loadbalancer_id = azurerm_lb.developer[each.key].id
  protocol        = "Tcp"
  port            = 80
}

resource "azurerm_lb_rule" "developer" {
  for_each = local.developers

  name                           = "rule-http"
  loadbalancer_id                = azurerm_lb.developer[each.key].id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "internal"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.developer[each.key].id]
  probe_id                       = azurerm_lb_probe.developer[each.key].id
}

resource "azurerm_network_interface" "app" {
  for_each = local.app_instances

  name                = "nic-${each.value.name}"
  location            = azurerm_resource_group.developer[each.value.dev_key].location
  resource_group_name = azurerm_resource_group.developer[each.value.dev_key].name
  tags                = merge(local.tags, { owner = each.value.dev_key })

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.app[each.value.dev_key].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_application_security_group_association" "app" {
  for_each = local.app_instances

  network_interface_id          = azurerm_network_interface.app[each.key].id
  application_security_group_id = azurerm_application_security_group.app[each.value.dev_key].id
}

resource "azurerm_network_interface_backend_address_pool_association" "app" {
  for_each = local.app_instances

  network_interface_id    = azurerm_network_interface.app[each.key].id
  ip_configuration_name   = "ipconfig"
  backend_address_pool_id = azurerm_lb_backend_address_pool.developer[each.value.dev_key].id
}

resource "azurerm_linux_virtual_machine" "app" {
  for_each = local.app_instances

  name                = each.value.name
  location            = azurerm_resource_group.developer[each.value.dev_key].location
  resource_group_name = azurerm_resource_group.developer[each.value.dev_key].name
  size                = var.app_vm_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.app[each.key].id
  ]
  tags = merge(local.tags, {
    owner = each.value.dev_key
    role  = "moodle"
  })

  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.ssh_public_key
  }

  os_disk {
    name                 = "disk-${each.value.name}-os"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init-app.yaml.tpl", {
    admin_username       = var.admin_username
    instance_name        = each.value.name
    storage_account_name = azurerm_storage_account.developer[each.value.dev_key].name
    storage_account_key  = azurerm_storage_account.developer[each.value.dev_key].primary_access_key
    file_share_name      = azurerm_storage_share.backups[each.value.dev_key].name
    blob_container_name  = azurerm_storage_container.moodle[each.value.dev_key].name
  }))

  depends_on = [
    azurerm_storage_share.backups,
    azurerm_storage_container.moodle
  ]
}

resource "azurerm_managed_disk" "app_data" {
  for_each = local.app_instances

  name                 = "disk-${each.value.name}-data"
  location             = azurerm_resource_group.developer[each.value.dev_key].location
  resource_group_name  = azurerm_resource_group.developer[each.value.dev_key].name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = merge(local.tags, { owner = each.value.dev_key })
}

resource "azurerm_virtual_machine_data_disk_attachment" "app_data" {
  for_each = local.app_instances

  managed_disk_id    = azurerm_managed_disk.app_data[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.app[each.key].id
  lun                = 0
  caching            = "ReadWrite"
}

resource "azurerm_role_assignment" "app_blob_data_contributor" {
  for_each = local.app_instances

  scope                = azurerm_storage_account.developer[each.value.dev_key].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.app[each.key].identity[0].principal_id
}

resource "azurerm_role_definition" "vm_power_operator" {
  name        = "${var.project}-${var.environment}-vm-power-operator-${random_string.suffix.result}"
  scope       = data.azurerm_subscription.current.id
  description = "Least-privilege VM power-state control for IRUO project."

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/instanceView/read",
      "Microsoft.Compute/virtualMachines/start/action",
      "Microsoft.Compute/virtualMachines/restart/action",
      "Microsoft.Compute/virtualMachines/deallocate/action",
      "Microsoft.Resources/subscriptions/resourceGroups/read"
    ]
    not_actions = []
  }

  assignable_scopes = [
    data.azurerm_subscription.current.id
  ]
}

resource "azurerm_role_assignment" "developer_power" {
  for_each = local.developer_principals

  scope              = azurerm_resource_group.developer[each.key].id
  role_definition_id = azurerm_role_definition.vm_power_operator.role_definition_resource_id
  principal_id       = each.value.principal_object_id
}

resource "azurerm_role_assignment" "lead_power_core" {
  for_each = local.lead_principals

  scope              = azurerm_resource_group.core.id
  role_definition_id = azurerm_role_definition.vm_power_operator.role_definition_resource_id
  principal_id       = each.value.principal_object_id
}

resource "azurerm_role_assignment" "lead_power_developers" {
  for_each = {
    for pair in setproduct(keys(local.lead_principals), keys(local.developers)) :
    "${pair[0]}-${pair[1]}" => {
      lead_key = pair[0]
      dev_key  = pair[1]
    }
  }

  scope              = azurerm_resource_group.developer[each.value.dev_key].id
  role_definition_id = azurerm_role_definition.vm_power_operator.role_definition_resource_id
  principal_id       = local.lead_principals[each.value.lead_key].principal_object_id
}
resource "azurerm_public_ip" "developer_nat" {
  for_each = azurerm_resource_group.developer

  name                = "pip-${var.project}-${var.environment}-${each.key}-nat"
  location            = each.value.location
  resource_group_name = each.value.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project     = var.project
    environment = var.environment
    owner       = each.key
    role        = "nat-outbound"
  }
}

resource "azurerm_nat_gateway" "developer" {
  for_each = azurerm_resource_group.developer

  name                = "nat-${var.project}-${var.environment}-${each.key}"
  location            = each.value.location
  resource_group_name = each.value.name
  sku_name            = "Standard"

  tags = {
    project     = var.project
    environment = var.environment
    owner       = each.key
    role        = "nat-outbound"
  }
}

resource "azurerm_nat_gateway_public_ip_association" "developer" {
  for_each = azurerm_nat_gateway.developer

  nat_gateway_id       = each.value.id
  public_ip_address_id = azurerm_public_ip.developer_nat[each.key].id
}

resource "azurerm_subnet_nat_gateway_association" "app" {
  for_each = azurerm_subnet.app

  subnet_id      = each.value.id
  nat_gateway_id = azurerm_nat_gateway.developer[each.key].id
}
