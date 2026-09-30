# Single AZ. EKS still wants control plane subnets in two AZs, so AZ2 only
# gets a tiny subnet for that.
#
#   workload           10.20.0.0/22    nodes, pods, tunnel host, lambda
#   control_plane_a/b  10.20.8.0/28, 10.20.8.16/28
#   endpoints          10.20.9.0/27
#   endpoints_secrets  10.20.9.32/28   sts + secretsmanager only
#   public             10.20.10.0/28   only if enable_nat
#
# control plane and the sts/secretsmanager endpoints get their own subnets so
# the ESO network policy can allow exactly those CIDRs.

locals {
  subnet_cidrs = {
    workload          = cidrsubnet(var.vpc_cidr, 6, 0)
    control_plane_a   = cidrsubnet(var.vpc_cidr, 12, 128)
    control_plane_b   = cidrsubnet(var.vpc_cidr, 12, 129)
    endpoints         = cidrsubnet(var.vpc_cidr, 11, 72)
    endpoints_secrets = cidrsubnet(var.vpc_cidr, 12, 146)
    public            = cidrsubnet(var.vpc_cidr, 12, 160)
  }

  private_subnets = {
    workload          = local.az_primary
    control_plane_a   = local.az_primary
    control_plane_b   = local.az_secondary
    endpoints         = local.az_primary
    endpoints_secrets = local.az_primary
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

# strip all rules from the default SG so nothing uses it by accident
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.subnet_cidrs[each.key]
  availability_zone       = each.value
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-${replace(each.key, "_", "-")}" }
}

# no default route -> no internet (unless enable_nat)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# --- optional NAT ---

resource "aws_internet_gateway" "main" {
  count  = var.enable_nat ? 1 : 0
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  count                   = var.enable_nat ? 1 : 0
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.subnet_cidrs.public
  availability_zone       = local.az_primary
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-public" }
}

resource "aws_route_table" "public" {
  count  = var.enable_nat ? 1 : 0
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "public_internet" {
  count                  = var.enable_nat ? 1 : 0
  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main[0].id
}

resource "aws_route_table_association" "public" {
  count          = var.enable_nat ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_eip" "nat" {
  count  = var.enable_nat ? 1 : 0
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  count         = var.enable_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

# --- flow logs ---

resource "aws_cloudwatch_log_group" "flow_logs" {
  # checkov:skip=CKV_AWS_338: short retention on purpose, poc cost
  name              = "/aws/vpc/${local.name}-flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

data "aws_iam_policy_document" "flow_logs_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:vpc-flow-log/*"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_trust.json
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "main" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60
}
