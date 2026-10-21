variable "name_prefix" {
  description = "Prefix applied to every resource name. The course guide mandates 'eda262-g07'."
  type        = string
}

variable "name_suffix" {
  description = "Workspace suffix (empty in the delivery workspace). See the data-lake module."
  type        = string
  default     = ""
}

variable "layer_buckets" {
  description = "Lake layer buckets keyed by layer (raw, trusted, refined), each with id and arn."
  type = map(object({
    id  = string
    arn = string
  }))
}

variable "layer_databases" {
  description = "Glue database name of each layer, keyed by layer."
  type        = map(string)
}

variable "athena_results_bucket" {
  description = "Athena results bucket (id and arn). Each persona WorkGroup writes under its own prefix."
  type = object({
    id  = string
    arn = string
  })
}

variable "personas" {
  description = "Access profiles: persona name -> description and the layers it may read. See the root variable for the policy itself."
  type = map(object({
    description = string
    layers      = list(string)
  }))
}

variable "persona_bytes_scanned_cutoff" {
  description = "Per-query scan cap (bytes) enforced on every persona WorkGroup."
  type        = number
}

variable "business_question_sql" {
  description = "Rendered business-question SQL, republished in the WorkGroup of every persona that can read refined."
  type        = string
}
