variable "project" {
  type        = string
  description = "Project tag and naming prefix."
  default     = "techsprint"
}

variable "environment" {
  type        = string
  description = "Environment tag."
  default     = "testing"
}

variable "location" {
  type        = string
  description = "Azure region."
  default     = "westeurope"
}

variable "users_csv_path" {
  type        = string
  description = "Path to semicolon-delimited CSV: ime;prezime;rola;principal_object_id"
  default     = "users.example.csv"
}

variable "admin_username" {
  type        = string
  description = "Linux admin username for all VMs."
  default     = "azureadmin"
}

variable "ssh_public_key" {
  type        = string
  description = "Optional SSH public key. If empty, Terraform generates a temporary key and outputs the private key as sensitive."
  default     = ""
  sensitive   = true
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR allowed to SSH to the public jump host. Use your public IP with /32 for real runs."
  default     = "0.0.0.0/0"
}

variable "lead_vnet_cidr" {
  type        = string
  description = "CIDR for the central team lead/jump host VNet."
  default     = "10.10.0.0/16"
}

variable "developer_vnet_base_octet" {
  type        = number
  description = "Second octet used to derive developer VNets as 10.<base+index>.0.0/16."
  default     = 20
}

variable "app_vm_size" {
  type        = string
  description = "Application VM size. B2s satisfies 2 vCPU / 4 GB RAM."
  default     = "Standard_B2s"
}

variable "jump_vm_size" {
  type        = string
  description = "Central jump/team lead VM size."
  default     = "Standard_B1s"
}

variable "os_disk_size_gb" {
  type        = number
  description = "OS disk size for all VMs."
  default     = 64
}

variable "data_disk_size_gb" {
  type        = number
  description = "Extra managed data disk size for each VM."
  default     = 32
}

variable "image_publisher" {
  type        = string
  description = "VM image publisher. Default is Ubuntu cloud image for reliable deployment; override for Rocky/CentOS if required by your Azure subscription."
  default     = "Canonical"
}

variable "image_offer" {
  type        = string
  description = "VM image offer."
  default     = "0001-com-ubuntu-server-jammy"
}

variable "image_sku" {
  type        = string
  description = "VM image SKU."
  default     = "22_04-lts-gen2"
}

variable "image_version" {
  type        = string
  description = "VM image version."
  default     = "latest"
}

