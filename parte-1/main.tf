locals {
  is_delivery_workspace = terraform.workspace == var.delivery_workspace

  # Delivery workspace -> exact mandated names. Any other workspace -> suffixed,
  # so parallel experiments never collide with the graded resources.
  name_suffix = local.is_delivery_workspace ? "" : "-${terraform.workspace}"
}

# Fails `plan` on the default workspace instead of silently provisioning a
# fourth, unnamed environment. Costs nothing: terraform_data holds no cloud resource.
resource "terraform_data" "workspace_guard" {
  input = terraform.workspace

  lifecycle {
    precondition {
      condition     = terraform.workspace != "default"
      error_message = "Refusing to run in the 'default' workspace. Run: terraform workspace new av1 (or select an existing one)."
    }
  }
}

module "data_lake" {
  source = "./modules/data-lake"

  name_prefix = var.name_prefix
  name_suffix = local.name_suffix

  glue_database_name = var.glue_database_name
  trusted_table_name = var.trusted_table_name

  bytes_scanned_cutoff_per_query = var.bytes_scanned_cutoff_per_query
}
