variable "aws_region" {
  description = "AWS region for the data lake. Must match the backend region."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS CLI profile to authenticate with. Empty uses the default credential chain."
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Mandatory resource prefix from the course guide."
  type        = string
  default     = "eda262-g07"
}

variable "delivery_workspace" {
  description = <<-EOT
    Terraform workspace that produces the exact resource names the course guide mandates
    (no suffix). Any other workspace gets its name appended as a suffix, so a throwaway
    test environment cannot collide with the graded one -- S3 bucket names are global.
  EOT
  type        = string
  default     = "av1"
}

variable "mandatory_tags" {
  description = "Tags the course guide requires on every AWS resource."
  type        = map(string)
  default = {
    turma   = "eda262"
    grupo   = "g07"
    projeto = "engenharia-de-dados"
  }

  validation {
    condition = alltrue([
      var.mandatory_tags["turma"] == "eda262",
      var.mandatory_tags["grupo"] == "g07",
      var.mandatory_tags["projeto"] == "engenharia-de-dados",
    ])
    error_message = "The course guide fixes these three tag values; changing them fails the acceptance script."
  }
}

variable "glue_database_name" {
  description = "Glue Data Catalog database name. Glue rejects hyphens, hence underscores."
  type        = string
  default     = "eda262_g07_kev"
}

variable "trusted_table_name" {
  description = "Name of the single trusted table modeled for Part 1."
  type        = string
  default     = "kev_vulnerabilities"
}

variable "bytes_scanned_cutoff_per_query" {
  description = "Per-query scan cap enforced by the Athena WorkGroup, in bytes."
  type        = number
  default     = 104857600 # 100 MB
}
