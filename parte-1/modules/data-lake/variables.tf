variable "name_prefix" {
  description = "Prefix applied to every resource name. The course guide mandates 'eda262-g07'."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name_prefix))
    error_message = "name_prefix must contain only lowercase letters, digits and hyphens (S3 bucket naming rules)."
  }
}

variable "name_suffix" {
  description = <<-EOT
    Suffix appended to every resource name, used to keep non-delivery Terraform workspaces
    from colliding with the graded resource names (S3 bucket names are globally unique).
    Must be empty in the delivery workspace so the mandated names are produced verbatim.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.name_suffix == "" || can(regex("^-[a-z0-9-]+$", var.name_suffix))
    error_message = "name_suffix must be empty or start with a hyphen followed by lowercase letters, digits or hyphens."
  }
}

variable "glue_database_name" {
  description = "Glue Data Catalog database holding the trusted table. Underscores only: Glue rejects hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9_]+$", var.glue_database_name))
    error_message = "Glue database names accept only lowercase letters, digits and underscores."
  }
}

variable "trusted_table_name" {
  description = "Name of the single trusted table modeled for Part 1."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9_]+$", var.trusted_table_name))
    error_message = "Glue table names accept only lowercase letters, digits and underscores."
  }
}

variable "trusted_table_prefix" {
  description = "S3 key prefix (no leading/trailing slash) under the trusted bucket backing the table."
  type        = string
  default     = "kev_vulnerabilities"
}

variable "raw_prefix" {
  description = "S3 key prefix (no leading/trailing slash) under the raw bucket holding the untouched source payload."
  type        = string
  default     = "kev"
}

variable "bytes_scanned_cutoff_per_query" {
  description = <<-EOT
    Hard per-query cap (bytes) enforced by the Athena WorkGroup. Athena cancels any query that
    would scan more than this. Acts as the cost guardrail for the graded query; AWS requires a
    minimum of 10 MB (10485760 bytes).
  EOT
  type        = number
  default     = 104857600 # 100 MB -- ~65x the current 1.6 MB dataset, still far below any runaway cost

  validation {
    condition     = var.bytes_scanned_cutoff_per_query >= 10485760
    error_message = "Athena requires bytes_scanned_cutoff_per_query to be at least 10485760 (10 MB)."
  }
}

variable "athena_results_retention_days" {
  description = "Days after which Athena query results are expired by S3 lifecycle, to avoid unbounded cost."
  type        = number
  default     = 7
}

variable "force_destroy_buckets" {
  description = <<-EOT
    Allow 'terraform destroy' to delete buckets that still contain objects (including old versions).
    Required by the rubric's 'destroy leaves no orphaned resources' criterion. Never enable this
    pattern on a bucket holding data you cannot re-ingest.
  EOT
  type        = bool
  default     = true
}
