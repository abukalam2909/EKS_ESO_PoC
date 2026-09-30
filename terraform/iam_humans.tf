# Three human roles, each mapped to the cluster with an access entry.
# The username prefix shows up in the audit log so it's clear who did what.
#
#   break-glass : cluster-admin. Emergency + the initial install. Every use alarms.
#   operator    : manages ExternalSecret/SecretStore/deployments in demo-app (RBAC in kubernetes/)
#   developer   : read-only in demo-app, no secrets

locals {
  human_trusted = length(var.human_principal_arns) > 0 ? var.human_principal_arns : [var.admin_principal_arn]

  human_roles = {
    break-glass = { k8s_groups = [], session_hours = 1 }
    operator    = { k8s_groups = ["platform-operators"], session_hours = 4 }
    developer   = { k8s_groups = ["developers"], session_hours = 8 }
  }
}

data "aws_iam_policy_document" "human_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = local.human_trusted
    }
  }
}

resource "aws_iam_role" "human" {
  for_each = local.human_roles

  name                 = "${local.name}-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.human_trust.json
  max_session_duration = each.value.session_hours * 3600
}

# enough to build a kubeconfig and open the SSM tunnel, nothing else in AWS
data "aws_iam_policy_document" "human" {
  statement {
    sid       = "DescribeCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.main.arn]
  }

  statement {
    sid     = "TunnelToTaggedHostOnly"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Purpose"
      values   = ["eks-tunnel"]
    }
  }

  statement {
    sid     = "PortForwardDocumentOnly"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:${local.partition}:ssm:${local.region}::document/AWS-StartPortForwardingSessionToRemoteHost",
    ]
  }

  statement {
    sid       = "OwnSessionsOnly"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:${local.partition}:ssm:*:${local.account_id}:session/$${aws:userid}-*"]
  }
}

resource "aws_iam_role_policy" "human" {
  for_each = aws_iam_role.human

  name   = "eks-access"
  role   = each.value.id
  policy = data.aws_iam_policy_document.human.json
}

resource "aws_eks_access_entry" "human" {
  for_each = aws_iam_role.human

  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = each.value.arn
  type              = "STANDARD"
  user_name         = "${each.key}:{{SessionName}}"
  kubernetes_groups = local.human_roles[each.key].k8s_groups
}

resource "aws_eks_access_policy_association" "break_glass" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.human["break-glass"].arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.human]
}
