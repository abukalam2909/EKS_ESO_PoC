resource "aws_sns_topic" "alerts" {
  name              = "${local.name}-security-alerts"
  kms_master_key_id = aws_kms_key.logs.arn
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "EventBridgeRules"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:events:${local.region}:${local.account_id}:rule/${local.name}-*"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# --- GetSecretValue on the demo secret by anyone not on the allowlist ---
#
# Allowlist is the app role (used by ESO) and the rotation lambda. Anything
# else alerts, including me as admin and denied attempts. Matching on
# userIdentity.arn so IAM users / root are caught too, not just roles.
# GetSecretValue is a read-only event, which EventBridge only delivers when
# the rule state is ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS.

locals {
  secret_read_allowlist = [
    "arn:${local.partition}:sts::${local.account_id}:assumed-role/${aws_iam_role.app_secret_reader.name}/*",
    "arn:${local.partition}:sts::${local.account_id}:assumed-role/${aws_iam_role.rotation.name}/*",
  ]
}

resource "aws_cloudwatch_event_rule" "secret_read" {
  name        = "${local.name}-unexpected-secret-read"
  description = "GetSecretValue on demo secrets by a principal not on the allowlist"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    source        = ["aws.secretsmanager"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["secretsmanager.amazonaws.com"]
      eventName   = ["GetSecretValue"]
      requestParameters = {
        # ESO asks by name, the lambda by ARN
        secretId = [
          { prefix = "demo/" },
          { prefix = "arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:demo/" },
        ]
      }
      userIdentity = {
        arn = [{ "anything-but" = { wildcard = local.secret_read_allowlist } }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "secret_read" {
  rule      = aws_cloudwatch_event_rule.secret_read.name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn
}
