# No NAT, so everything AWS goes through endpoints.
# ec2 is needed by the VPC CNI and the node AMI, eks for update-kubeconfig /
# node registration, ssm* for the tunnel host.

locals {
  general_endpoints = ["ec2", "ecr.api", "ecr.dkr", "logs", "kms", "eks", "ssm", "ssmmessages", "ec2messages"]

  # ESO only talks to these two, so they get their own subnet
  secrets_endpoints = ["sts", "secretsmanager"]
}

resource "aws_security_group" "endpoints" {
  name        = "${local.name}-vpc-endpoints"
  description = "HTTPS from the workload subnet to the interface endpoints"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from workload subnet"
  cidr_ipv4         = local.subnet_cidrs.workload
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# default for most endpoints: only principals from this account
data "aws_iam_policy_document" "endpoint_default" {
  # checkov:skip=CKV_AWS_1: endpoint policy, only limits what can pass through; IAM still applies
  # checkov:skip=CKV_AWS_49: same as above
  statement {
    actions   = ["*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_vpc_endpoint" "general" {
  for_each = toset(local.general_endpoints)

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private["endpoints"].id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  policy              = data.aws_iam_policy_document.endpoint_default.json
  tags                = { Name = "${local.name}-${each.value}" }
}

# secrets manager: own-account principals, and only the demo/ secrets
data "aws_iam_policy_document" "endpoint_secretsmanager" {
  statement {
    actions   = ["secretsmanager:*"]
    resources = ["arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:demo/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [local.account_id]
    }
  }

  # rotation lambda uses this, it has no resource
  statement {
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [local.account_id]
    }
  }
}

# sts: AssumeRoleWithWebIdentity is called with no AWS identity (just the
# k8s token) so a PrincipalAccount condition would break IRSA. Limit it to
# roles in this account instead.
data "aws_iam_policy_document" "endpoint_sts" {
  statement {
    actions   = ["sts:AssumeRoleWithWebIdentity"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    actions   = ["sts:AssumeRole", "sts:GetCallerIdentity", "sts:TagSession"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private["endpoints_secrets"].id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  policy              = data.aws_iam_policy_document.endpoint_secretsmanager.json
  tags                = { Name = "${local.name}-secretsmanager" }
}

resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private["endpoints_secrets"].id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  policy              = data.aws_iam_policy_document.endpoint_sts.json
  tags                = { Name = "${local.name}-sts" }
}

# s3 gateway: ECR layer bucket + buckets in this account
data "aws_iam_policy_document" "endpoint_s3" {
  statement {
    sid       = "EcrLayers"
    actions   = ["s3:GetObject"]
    resources = ["arn:${local.partition}:s3:::prod-${local.region}-starport-layer-bucket/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "OwnAccountBuckets"
    actions   = ["s3:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  policy            = data.aws_iam_policy_document.endpoint_s3.json
  tags              = { Name = "${local.name}-s3" }
}
