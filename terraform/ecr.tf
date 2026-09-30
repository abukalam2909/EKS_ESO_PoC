# No internet from the cluster, so every non-AWS image is copied here from my
# laptop first (DEPLOY.md). Gatekeeper only allows images from this registry.

locals {
  mirrored_images = [
    "external-secrets",
    "gatekeeper",
    "busybox",
    "kube-bench",
  ]
}

resource "aws_ecr_repository" "mirror" {
  for_each = toset(local.mirrored_images)

  name = "mirror/${each.value}"

  # a digest-pinned image can't change under a tag
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  # poc: let terraform destroy clean up repos that still have images
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "mirror" {
  for_each   = aws_ecr_repository.mirror
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
