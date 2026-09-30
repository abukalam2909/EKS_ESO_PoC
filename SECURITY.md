# Security

Report problems through a private GitHub security advisory, not a public issue.

## Residual risks

- **The Kubernetes Secret exists.** Break-glass, ESO, the kubelet on the pod's
  node, and anyone who can deploy into `demo-app` (the operator role) can get
  the value. KMS encryption covers etcd, not the API.
- **ESO controller permissions.** In `demo-app` it can get/list/watch/create/
  update/delete Secrets and mint tokens for `secret-reader` (so it can assume
  the app's AWS role). That's its job and can't be removed. It has nothing
  outside `demo-app` apart from leader election in its own namespace. The
  cert-controller can update ESO's own two webhook configs and its own cert
  secret, by name.
- **Node compromise** exposes every Secret and token on that node. One shared
  node group.
- **Break-glass** is cluster-admin and is used for the install. Visible in the
  audit log (`break-glass:` username) but not alerted on.
- **One account, one admin.** The admin could disable CloudTrail or the alert.
  It can't decrypt the secret (not a key user). Keys have no root `kms:*`, so
  deleting the admin role would lock the keys.
- **Admin exception** in the secret policy (VPC endpoint rule, reader list) so
  Terraform works from a laptop. A read would fail on KMS and trigger the alert.
- **Synthetic rotation.** No downstream system, so `setSecret` does nothing.
  New values reach the pod within ~1h (ESO refresh) + ~2 min (kubelet) unless
  a sync is forced.
- **Network gaps.** DNS tunnelling (no DNS Firewall); new pods are briefly
  unrestricted until the VPC CNI applies policies (standard mode).
- **Supply chain.** Images pinned by digest from our ECR, but signatures aren't
  verified. ESO still installs its namespaced generator CRDs; Gatekeeper blocks
  their use.
- **Minimal detection** by choice: only the GetSecretValue alert.
- **Cost shortcuts:** single AZ, 14-day logs, single replicas.

## Accepted scanner findings

| Finding | Why |
|---------|-----|
| Short log retention (Checkov CKV_AWS_338) | POC cost |
| Trail bucket without access logs/replication/notifications, trail not in CloudWatch (CKV_AWS_18, 144, CKV2_AWS_62, 10, CKV_AWS_252) | Out of scope; alerts use EventBridge |
| Rotation Lambda without X-Ray, reserved concurrency, DLQ, code signing (CKV_AWS_50, 115, 116, 272) | No X-Ray endpoint; 10-concurrency limit on new accounts; Secrets Manager retries; overkill for one function |
| cert-controller webhook config and secret access (Trivy KSV-0113, KSV-0114, Checkov CKV_K8S_155) | Needed to manage its own cert; limited by name |
| Operator can manage deployments (Trivy KSV-0048) | That's the role |

Key policy `Resource: "*"`, endpoint policies and Checkov's outdated EKS
version list are false positives, suppressed inline with a reason.

## Runbooks

**Secret leaked** - rotate first, clean up after.
1. `aws secretsmanager rotate-secret --secret-id demo/app/api-key`
2. `kubectl annotate externalsecret app-api-key -n demo-app force-sync=$(date +%s) --overwrite`
3. Check `kubectl logs deploy/demo-app -n demo-app --tail=1` shows a new hash.
4. Check CloudTrail / EKS audit for who could have read it, then purge it from
   wherever it leaked (e.g. `git filter-repo`).

**AWS credentials exposed** - IAM user keys: deactivate and delete. Role
sessions: "Revoke active sessions" on the role. Check CloudTrail for what they
did; if they could read the secret, rotate it.

**ESO controller compromised** - `kubectl scale deploy external-secrets -n external-secrets --replicas=0`
(running pods keep working), rotate the secret, revoke the app role's sessions,
review audit logs for the ESO service account, redeploy from a known digest.

**GetSecretValue alert** - read `userIdentity.arn`, `sourceIPAddress` and
`errorCode` in the event. Denied: find out who and why. Succeeded: shouldn't be
possible for anyone off the allowlist - check the secret and key policies
against Terraform, rotate, revoke sessions.

## In production I would add

- Multi-account setup with SCPs protecting the controls (no stopping CloudTrail
  / Config / GuardDuty, no deleting or disabling the CMKs, no public EKS
  endpoint, no IAM access keys).
- Organization CloudTrail to a log archive account, Config conformance packs,
  Security Hub and GuardDuty aggregated to a security account.
- Break-glass alarm, tamper alerts and audit log queries.
- Secrets in a shared account, read cross-account via resource and key policies
  scoped to the org and role.
- Three AZs, DNS Firewall, image signature checks, CI running the scanners,
  per-team node groups, remote Terraform state, longer log retention.
