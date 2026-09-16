variable "aws_region" {
  description = "AWS region hosting the Terraform state backend. Must match the region used by parte-1/."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Mandatory resource prefix from the course guide."
  type        = string
  default     = "eda262-g07"
}

variable "mandatory_tags" {
  description = "Tags the course guide requires on every AWS resource."
  type        = map(string)
  default = {
    turma   = "eda262"
    grupo   = "g07"
    projeto = "engenharia-de-dados"
  }
}

variable "force_destroy" {
  description = "Allow destroying the state bucket even if it still holds state versions. Keep true for the graded teardown."
  type        = bool
  default     = true
}
