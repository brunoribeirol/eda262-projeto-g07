output "state_bucket" {
  description = "S3 bucket holding the parte-2 Terraform state."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "DynamoDB table used for Terraform state locking."
  value       = aws_dynamodb_table.lock.name
}

output "region" {
  description = "Region of the backend resources."
  value       = var.aws_region
}

# Rendered straight into parte-2/backend.hcl by scripts/part-2/bootstrap.sh, so the
# backend configuration is never hand-typed.
output "backend_hcl" {
  description = "Ready-to-use `terraform init -backend-config=` file contents."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.state.id}"
    key            = "eda262-g07/parte-2/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.lock.name}"
    encrypt        = true
  EOT
}
