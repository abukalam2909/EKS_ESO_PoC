"""Rotation for the demo secret.

Standard four-step Secrets Manager rotation. The value is a random API-key
style string with no downstream system, so setSecret has nothing to do and
testSecret only checks the format. The value itself is never logged.
"""

import logging

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sm = boto3.client("secretsmanager")

KEY_LENGTH = 40


def lambda_handler(event, context):
    arn = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]

    meta = sm.describe_secret(SecretId=arn)
    if not meta.get("RotationEnabled"):
        raise ValueError("rotation is not enabled for this secret")

    stages = meta.get("VersionIdsToStages", {})
    if token not in stages:
        raise ValueError("version %s is not a version of this secret" % token)
    if "AWSCURRENT" in stages[token]:
        logger.info("version %s already AWSCURRENT, nothing to do", token)
        return
    if "AWSPENDING" not in stages[token]:
        raise ValueError("version %s is not AWSPENDING" % token)

    steps = {
        "createSecret": create_secret,
        "setSecret": set_secret,
        "testSecret": test_secret,
        "finishSecret": finish_secret,
    }
    if step not in steps:
        raise ValueError("unknown step %s" % step)
    steps[step](arn, token, stages)


def create_secret(arn, token, stages):
    # idempotent: a retried createSecret must not generate a second value
    try:
        sm.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")
        logger.info("createSecret: pending version already exists")
        return
    except sm.exceptions.ResourceNotFoundException:
        pass

    # unlike the AWS template this does not require an AWSCURRENT first, so the
    # very first rotation can create the initial value
    value = sm.get_random_password(PasswordLength=KEY_LENGTH, ExcludePunctuation=True)["RandomPassword"]
    sm.put_secret_value(
        SecretId=arn,
        ClientRequestToken=token,
        SecretString=value,
        VersionStages=["AWSPENDING"],
    )
    logger.info("createSecret: new pending version stored")


def set_secret(arn, token, stages):
    # a real credential would be pushed to the downstream system here
    logger.info("setSecret: no downstream system for the demo value")


def test_secret(arn, token, stages):
    value = sm.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")["SecretString"]
    if len(value) != KEY_LENGTH or not value.isalnum():
        raise ValueError("pending value failed format check")
    logger.info("testSecret: format ok")


def finish_secret(arn, token, stages):
    current = next((v for v, s in stages.items() if "AWSCURRENT" in s), None)
    kwargs = {"SecretId": arn, "VersionStage": "AWSCURRENT", "MoveToVersionId": token}
    if current:
        kwargs["RemoveFromVersionId"] = current
    sm.update_secret_version_stage(**kwargs)
    logger.info("finishSecret: %s is now AWSCURRENT", token)
