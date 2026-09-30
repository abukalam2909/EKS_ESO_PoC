locals {
  rotation_fn = "${local.name}-secret-rotation"
}

data "archive_file" "rotation" {
  type        = "zip"
  source_file = "${path.module}/rotation_lambda/app.py"
  output_path = "${path.module}/build/rotation.zip"
}

resource "aws_cloudwatch_log_group" "rotation" {
  # checkov:skip=CKV_AWS_338: short retention on purpose, poc cost
  name              = "/aws/lambda/${local.rotation_fn}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

data "aws_iam_policy_document" "rotation_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rotation" {
  name               = local.rotation_fn
  assume_role_policy = data.aws_iam_policy_document.rotation_trust.json
}

data "aws_iam_policy_document" "rotation" {
  # checkov:skip=CKV_AWS_111: ENI actions for a VPC lambda don't support resource scoping
  # checkov:skip=CKV_AWS_356: same, plus GetRandomPassword has no resource
  statement {
    sid = "ThisSecretOnly"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = [aws_secretsmanager_secret.app.arn]
  }

  statement {
    sid       = "RandomValue"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.rotation.arn}:*"]
  }

  statement {
    sid = "VpcEni"
    actions = [
      "ec2:AssignPrivateIpAddresses",
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "rotation" {
  name   = "rotate-demo-secret"
  role   = aws_iam_role.rotation.id
  policy = data.aws_iam_policy_document.rotation.json
}

# only needs to reach the secrets manager endpoint
resource "aws_security_group" "rotation" {
  name        = local.rotation_fn
  description = "Rotation lambda, egress to secrets manager endpoint only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_egress_rule" "rotation" {
  security_group_id = aws_security_group.rotation.id
  description       = "secrets manager endpoint"
  cidr_ipv4         = local.subnet_cidrs.endpoints_secrets
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_lambda_function" "rotation" {
  # checkov:skip=CKV_AWS_50: no xray endpoint in the vpc, tracing would go nowhere
  # checkov:skip=CKV_AWS_115: reserved concurrency fails on new accounts with a 10 limit
  # checkov:skip=CKV_AWS_116: invoked synchronously by secrets manager, which retries
  # checkov:skip=CKV_AWS_272: code signing is overkill for one small function in a poc
  function_name    = local.rotation_fn
  role             = aws_iam_role.rotation.arn
  runtime          = "python3.14"
  handler          = "app.lambda_handler"
  filename         = data.archive_file.rotation.output_path
  source_code_hash = data.archive_file.rotation.output_base64sha256
  timeout          = 30

  vpc_config {
    subnet_ids         = [aws_subnet.private["workload"].id]
    security_group_ids = [aws_security_group.rotation.id]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.rotation.name
  }

  depends_on = [aws_iam_role_policy.rotation]
}

resource "aws_lambda_permission" "rotation" {
  statement_id   = "SecretsManagerInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.rotation.function_name
  principal      = "secretsmanager.amazonaws.com"
  source_arn     = aws_secretsmanager_secret.app.arn
  source_account = local.account_id
}

# rotate_immediately creates the first value right after apply
resource "aws_secretsmanager_secret_rotation" "app" {
  secret_id           = aws_secretsmanager_secret.app.id
  rotation_lambda_arn = aws_lambda_function.rotation.arn
  rotate_immediately  = true

  rotation_rules {
    automatically_after_days = var.rotation_days
  }

  depends_on = [aws_lambda_permission.rotation]
}
