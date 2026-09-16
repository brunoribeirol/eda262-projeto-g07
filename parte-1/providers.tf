provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  # The course guide mandates these tags on every resource. Setting them here
  # instead of per-resource makes it impossible for a new resource to miss them.
  default_tags {
    tags = merge(
      var.mandatory_tags,
      {
        workspace = terraform.workspace
        managedBy = "terraform"
      },
    )
  }
}
