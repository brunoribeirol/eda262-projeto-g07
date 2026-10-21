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

variable "pipeline_bytes_scanned_cutoff" {
  description = "Hard per-query scan cap (bytes) enforced by the pipeline WorkGroup. AWS minimum is 10 MB."
  type        = number

  validation {
    condition     = var.pipeline_bytes_scanned_cutoff >= 10485760
    error_message = "Athena requires bytes_scanned_cutoff_per_query to be at least 10485760 (10 MB)."
  }
}

variable "cost_target_bytes_per_query" {
  description = "Declared cost target for the business question, in bytes scanned per execution. Exposed as an output for the cost check."
  type        = number
}

variable "athena_results_retention_days" {
  description = "Days after which Athena query results are expired by S3 lifecycle, to avoid unbounded cost."
  type        = number
  default     = 7
}

variable "force_destroy_buckets" {
  description = <<-EOT
    Allow 'terraform destroy' to delete buckets that still contain objects (including old versions).
    Required by the rubric's 'destroy leaves no orphaned resources' criterion. Acceptable only
    because every byte in the lake is re-ingestible from public feeds with one command.
  EOT
  type        = bool
  default     = true
}
