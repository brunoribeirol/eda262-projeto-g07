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
  default     = "av2"
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

variable "pipeline_bytes_scanned_cutoff" {
  description = <<-EOT
    Per-query scan cap (bytes) for the pipeline WorkGroup, which runs the raw -> trusted ->
    refined INSERTs and the cost comparison. The largest legitimate statement is a 30-day
    EPSS batch read from raw: 80,917,274 bytes measured on 2026-10-20. 200 MB leaves ~2.5x
    headroom and still cancels a runaway full-history scan.
  EOT
  type        = number
  default     = 209715200 # 200 MB

  validation {
    condition     = var.pipeline_bytes_scanned_cutoff >= 10485760
    error_message = "Athena requires a per-query cutoff of at least 10485760 bytes (10 MB)."
  }
}

variable "persona_bytes_scanned_cutoff" {
  description = <<-EOT
    Per-query scan cap (bytes) for the persona WorkGroups (data-engineer, data-analyst,
    business-user). Same 100 MB guardrail as Part 1: personas query trusted/refined, where
    a 30-day analysis reads ~39 MB of Parquet columns.
  EOT
  type        = number
  default     = 104857600 # 100 MB

  validation {
    condition     = var.persona_bytes_scanned_cutoff >= 10485760
    error_message = "Athena requires a per-query cutoff of at least 10485760 bytes (10 MB)."
  }
}

variable "cost_target_bytes_per_query" {
  description = <<-EOT
    Declared cost target for the business question: at most this many bytes scanned per
    execution. 10 MB is one Athena billing unit -- the cheapest a query can ever be
    (USD 0.00004768 at us-east-1 pricing). scripts/part-2/run_query.sh measures the real
    DataScannedInBytes against this value and fails if the target is missed.
  EOT
  type        = number
  default     = 10485760 # 10 MB

  validation {
    condition     = var.cost_target_bytes_per_query > 0
    error_message = "The cost target must be a positive number of bytes."
  }
}

variable "personas" {
  description = <<-EOT
    Who may read which lake layer. This map IS the access policy: the governance module turns
    each entry into an IAM role, an isolated Athena WorkGroup and the Lake Formation grants for
    the listed layers -- nothing else. Writes are reserved to the pipeline (the deploying
    principal, a Lake Formation administrator).
  EOT
  type = map(object({
    description = string
    layers      = list(string)
  }))
  default = {
    data-engineer = {
      description = "Builds and debugs the pipeline: reads every layer, including the untouched source data."
      layers      = ["raw", "trusted", "refined"]
    }
    data-analyst = {
      description = "Explores cleaned, typed data: reads trusted and refined, never the raw payloads."
      layers      = ["trusted", "refined"]
    }
    business-user = {
      description = "Consumes the answer: reads only the refined, business-ready aggregate."
      layers      = ["refined"]
    }
  }

  validation {
    condition = alltrue(flatten([
      for p in values(var.personas) : [for l in p.layers : contains(["raw", "trusted", "refined"], l)]
    ]))
    error_message = "Persona layers must be drawn from: raw, trusted, refined."
  }

  validation {
    condition     = alltrue([for name in keys(var.personas) : can(regex("^[a-z][a-z-]{2,30}$", name))])
    error_message = "Persona names must be lowercase letters and hyphens (they become IAM role and WorkGroup names)."
  }
}
