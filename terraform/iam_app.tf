# IRSA for the app. The role is bound to the secret-reader SA, which runs no
# pods; only the SecretStore uses it. The app pod runs as a different SA with
# no AWS access. ESO's own SA gets no role at all.

resource "aws_iam_openid_connect_provider" "eks" {
  url            = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  oidc_host = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

data "aws_iam_policy_document" "app_secret_reader_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    # exact namespace + SA, no wildcards
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${local.app_namespace}:${local.secret_reader_sa}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_secret_reader" {
  name                 = "${local.name}-app-secret-reader"
  assume_role_policy   = data.aws_iam_policy_document.app_secret_reader_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "app_secret_reader" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.app.arn]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.secrets.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [aws_secretsmanager_secret.app.arn]
    }
  }
}

resource "aws_iam_role_policy" "app_secret_reader" {
  name   = "read-demo-secret"
  role   = aws_iam_role.app_secret_reader.id
  policy = data.aws_iam_policy_document.app_secret_reader.json
}
