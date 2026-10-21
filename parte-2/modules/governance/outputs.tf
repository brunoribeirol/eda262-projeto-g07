output "personas" {
  description = "Per persona: IAM role ARN, Athena WorkGroup and the layers it may read."
  value = {
    for persona, cfg in var.personas : persona => {
      role_arn  = aws_iam_role.persona[persona].arn
      workgroup = aws_athena_workgroup.persona[persona].name
      layers    = cfg.layers
    }
  }
}

output "access_matrix" {
  description = "Expected outcome of every (persona, layer) read: true = granted by Lake Formation."
  value = {
    for persona, cfg in var.personas : persona => {
      for layer in keys(var.layer_buckets) : layer => contains(cfg.layers, layer)
    }
  }
}

output "registered_locations" {
  description = "S3 locations registered with Lake Formation."
  value       = [for r in aws_lakeformation_resource.layer : r.arn]
}

output "lakeformation_data_access_role_arn" {
  description = "Role Lake Formation assumes to read the registered buckets."
  value       = aws_iam_role.lakeformation_data_access.arn
}
