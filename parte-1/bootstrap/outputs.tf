output "state_bucket" {
  description = "S3 bucket holding the parte-1 Terraform state."
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

# Rendered straight into parte-1/backend.hcl by scripts/bootstrap.sh, so the
# backend configuration is never hand-typed.
output "backend_hcl" {
  description = "Ready-to-use `terraform init -backend-config=` file contents."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.state.id}"
    key            = "eda262-g07/parte-1/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.lock.name}"
    encrypt        = true
  EOT
}
