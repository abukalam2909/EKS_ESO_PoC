locals {
  cluster_name = "${local.name}-eks"

  # fixed so the network policies can reference the kubernetes service IP
  service_cidr = "172.20.0.0/16"
}

data "aws_iam_policy_document" "cluster_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_trust.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# EKS writes to this name, create it first so it's encrypted and has retention
resource "aws_cloudwatch_log_group" "eks" {
  # checkov:skip=CKV_AWS_338: short retention on purpose, poc cost
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

resource "aws_security_group" "cluster" {
  name        = "${local.cluster_name}-api"
  description = "Extra SG on the control plane ENIs"
  vpc_id      = aws_vpc.main.id
}

# nodes already get in through the EKS-managed cluster SG, so this only
# needs the tunnel host
resource "aws_vpc_security_group_ingress_rule" "cluster_api" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "kube-apiserver from the tunnel host"
  referenced_security_group_id = aws_security_group.admin_host.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_eks_cluster" "main" {
  # checkov:skip=CKV_AWS_339: checkov's version list is behind, 1.36 is in EKS standard support
  name     = local.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = [aws_subnet.private["control_plane_a"].id, aws_subnet.private["control_plane_b"].id]
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    # public only when the temporary exception is used
    endpoint_public_access = length(var.public_endpoint_cidrs) > 0
    public_access_cidrs    = length(var.public_endpoint_cidrs) > 0 ? var.public_endpoint_cidrs : null
  }

  kubernetes_network_config {
    service_ipv4_cidr = local.service_cidr
  }

  # envelope encryption with my own key instead of the default AWS owned one
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # access entries only, no aws-auth configmap, and the creator doesn't get
  # silent cluster-admin
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  # don't drift into paid extended support
  upgrade_policy {
    support_type = "STANDARD"
  }

  # add-ons are installed as managed add-ons with pinned versions (nodes.tf)
  bootstrap_self_managed_addons = false

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.eks,
  ]
}
