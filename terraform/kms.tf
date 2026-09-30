# One CMK per purpose (logs, eks, ebs, secrets).
# No root kms:* statement - the key policy is the only thing granting access.
# Admin can manage keys but can't encrypt/decrypt.
# Careful: if admin_principal_arn gets deleted the keys become unmanageable.

locals {
  kms_admin_actions = [
    "kms:CancelKeyDeletion",
    "kms:CreateAlias",
    "kms:DeleteAlias",
    "kms:DescribeKey",
    "kms:DisableKey",
    "kms:DisableKeyRotation",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListAliases",
    "kms:ListGrants",
    "kms:ListKeyPolicies",
    "kms:ListKeyRotations",
    "kms:ListResourceTags",
    "kms:PutKeyPolicy",
    "kms:RetireGrant",
    "kms:RevokeGrant",
    "kms:RotateKeyOnDemand",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateAlias",
    "kms:UpdateKeyDescription",
  ]

  running_as_admin = data.aws_iam_session_context.current.issuer_arn == var.admin_principal_arn

  secret_arn_pattern = "arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:${local.secret_name}-??????"
}

data "aws_iam_policy_document" "kms_logs" {
  # checkov:skip=CKV_AWS_111: key policy, "*" is this key
  # checkov:skip=CKV_AWS_356: key policy, "*" is this key
  statement {
    sid       = "KeyAdmins"
    actions   = local.kms_admin_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.admin_principal_arn]
    }
  }

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "${local.name} logs"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms_logs.json

  lifecycle {
    precondition {
      condition     = local.running_as_admin
      error_message = "Run terraform as admin_principal_arn or you can lock yourself out of the key."
    }
  }
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

data "aws_iam_policy_document" "kms_eks" {
  # checkov:skip=CKV_AWS_111: key policy, "*" is this key
  # checkov:skip=CKV_AWS_356: key policy, "*" is this key
  statement {
    sid       = "KeyAdmins"
    actions   = local.kms_admin_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.admin_principal_arn]
    }
  }

  # CreateCluster needs the caller to create a grant for EKS.
  # GrantIsForAWSResource stops the admin granting it to anyone else.
  statement {
    sid       = "AdminGrantToEksOnly"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.admin_principal_arn]
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  statement {
    sid       = "ClusterRole"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey", "kms:ListGrants"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.cluster.arn]
    }
  }
}

resource "aws_kms_key" "eks" {
  description             = "${local.name} eks secrets encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms_eks.json

  lifecycle {
    precondition {
      condition     = local.running_as_admin
      error_message = "Run terraform as admin_principal_arn or you can lock yourself out of the key."
    }
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

data "aws_iam_policy_document" "kms_ebs" {
  # checkov:skip=CKV_AWS_111: key policy, "*" is this key
  # checkov:skip=CKV_AWS_356: key policy, "*" is this key
  statement {
    sid       = "KeyAdmins"
    actions   = local.kms_admin_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.admin_principal_arn]
    }
  }

  # same idea as the aws/ebs managed key: usable by the account but only via
  # EC2 in this region. covers the autoscaling service-linked role that
  # launches the node group instances.
  statement {
    sid = "ViaEc2InThisAccount"
    actions = [
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ec2.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "ebs" {
  description             = "${local.name} ebs volumes"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms_ebs.json

  lifecycle {
    precondition {
      condition     = local.running_as_admin
      error_message = "Run terraform as admin_principal_arn or you can lock yourself out of the key."
    }
  }
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${local.name}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

data "aws_iam_policy_document" "kms_secrets" {
  # checkov:skip=CKV_AWS_111: key policy, "*" is this key
  # checkov:skip=CKV_AWS_356: key policy, "*" is this key
  statement {
    sid       = "KeyAdmins"
    actions   = local.kms_admin_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.admin_principal_arn]
    }
  }

  # app role can decrypt only through secrets manager and only for this
  # secret. StringLike because the ARN has a random suffix and pointing at the
  # real ARN here would be a dependency cycle. The IAM policy uses the exact ARN.
  statement {
    sid       = "AppRoleDecrypt"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.app_secret_reader.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [local.secret_arn_pattern]
    }
  }

  # admin is intentionally not a key user: can manage the secret, can't read it
}

resource "aws_kms_key" "secrets" {
  description             = "${local.name} secrets manager"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms_secrets.json

  lifecycle {
    precondition {
      condition     = local.running_as_admin
      error_message = "Run terraform as admin_principal_arn or you can lock yourself out of the key."
    }
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}
