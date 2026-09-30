# Security

What this POC does not protect against, what's accepted and why, and what to do
when something goes wrong.

If you find a problem in this repo, please open a private security advisory on
GitHub rather than a public issue.

## Residual risks

These are known and accepted for a POC. Most are inherent to the design, not
things that were forgotten.

### 1. A Kubernetes Secret exists in the cluster

ESO's model is to sync into a native Secret. That Secret can be read by:

- **break-glass** (cluster-admin)
- **the ESO controller** (it writes it)
- **the platform operator, indirectly** - the operator can't `get` Secrets,
  but it can create a Deployment whose pod mounts `app-api-key` and prints it.
  Gatekeeper and PSA limit what that pod can be (no privileged, must be from
  our ECR, no env vars), not whether it can read a file it mounted. Anyone who
  can deploy into the namespace should be treated as able to read its secrets.
  In production that's the CD pipeline, not a person.
- **the kubelet on the node running the pod** (Node authorizer)

KMS envelope encryption protects etcd storage and backups. It does not help
against any of the above. If the requirement is that no Secret object may
exist at all, use the Secrets Store CSI Driver ([ADR 0002](docs/adr/0002-eso-vs-secrets-store-csi-driver.md)).

### 2. What the ESO controller can still do

After all the scoping, the controller's service account
(`external-secrets/external-secrets`) holds:

| Where | Resource | Verbs |
|-------|----------|-------|
| demo-app | secrets | get, list, watch, create, update, patch, delete |
| demo-app | serviceaccounts/token, only `secret-reader` | create |
| demo-app | serviceaccounts, namespaces, configmaps | get, list, watch |
| demo-app | externalsecrets, secretstores (+ status, finalizers) | get, list, watch, update, patch |
| demo-app | generators.external-secrets.io/generatorstates | full |
| demo-app | other generator kinds | get, list, watch |
| demo-app | events | create, patch |
| external-secrets | configmaps, leases (leader election) | get, create, update, patch |

The cert-controller SA holds get/list/watch on CRDs and validating webhook
configurations cluster-wide, update/patch on ESO's two CRDs and two webhook
configurations by name, and get/update/patch on its own webhook cert secret.
The webhook SA has no RBAC.

Why this can't go lower:

- **Secrets read/write** is the controller's job - it creates and updates the
  synced Secret. `list/watch` are needed for its informer; RBAC can't restrict
  those by name.
- **Minting `secret-reader` tokens** is how it authenticates to AWS for the
  namespace. With that token it can assume the app role and read the app's AWS
  secret. So a compromised controller = that namespace's secrets, in AWS and in
  the cluster. It can't reach other namespaces, `kube-system`, or any AWS
  resource the app role can't.
- **Webhook config updates** are how the cert-controller injects its CA; they
  are limited to ESO's own webhooks, so the worst case is breaking ESO's
  validation, not Gatekeeper's.

### 3. Node compromise

Anyone with root on a node gets the node role, the kubelet's credentials, every
Secret mounted by pods on that node, and projected tokens of those pods. The
single shared node group means all workloads share that blast radius. Hop limit
1 and PSA stop pods from getting to the node, not attackers who already are on
it.

### 4. Break-glass is all-powerful

The break-glass role is cluster-admin and is also used for the initial install.
Its actions show up in the EKS audit log under the `break-glass:` username
prefix, but nothing alerts on it (the alarm was cut from scope). Its AWS
permissions are only DescribeCluster and SSM port forwarding, and it isn't on
the secret's reader list.

### 5. Single account, single admin

The admin role that runs Terraform manages every KMS key and the secret policy
and could turn off CloudTrail, the alert or anything else. Nothing prevents or
alerts on that. The fix is organisational (SCPs, separate security account),
see below. The admin cannot decrypt the secret: it isn't a key user on the
secrets CMK.

### 6. Admin exception in the secret policy

The admin role is exempt from the "only through the VPC endpoint" rule so
Terraform can manage the secret from a laptop, and is on the GetSecretValue
reader list so it can't lock itself out. Stolen admin credentials could
therefore call GetSecretValue from anywhere - it would fail on KMS, and it
would trigger the alert.

### 7. KMS lockout

Key policies have no root `kms:*` statement, so the admin role is the only key
administrator. If that role is deleted or recreated, the keys become
unmanageable until AWS Support helps. Terraform refuses to run as anyone else
to avoid creating this by accident.

### 8. Rotation is on a synthetic value

The rotation Lambda generates a random API-key-style value. There's no
downstream system, so `setSecret` does nothing and `testSecret` only checks the
format. For a real credential (database password, API key at a vendor) the
Lambda has to set it on the other side and test it before `finishSecret`.

Propagation isn't instant: ESO polls hourly, then the kubelet takes up to a
minute or two to update the file. Worst case about an hour and two minutes
unless someone forces a sync.

### 9. Network

- **DNS tunnelling.** No internet route, but CoreDNS forwards to the VPC
  resolver, which resolves public names. Route 53 Resolver DNS Firewall would
  close that; not included.
- **Policy gap at pod start.** The VPC CNI network policy agent runs in
  standard mode: a new pod is unrestricted for a moment until its policies are
  applied. Strict mode fixes it but needs policies for `kube-system` too.
- **Endpoints allow any action by in-account principals** (except the Secrets
  Manager endpoint, which is limited to `demo/*`). IAM is still the real limit.

### 10. Supply chain

Images are pinned by digest and pulled only from our ECR, but nothing verifies
signatures before they're mirrored. Pinning means "exactly what I tested", not
"safe". ESO also still installs its namespaced generator CRDs (the chart has no
switch); Gatekeeper blocks creating them.

### 11. Detection is minimal on purpose

Only unexpected GetSecretValue calls alert. No break-glass alarm, no alerts on
controls being disabled, no saved audit log queries, no GuardDuty, no AWS
Config. The logs needed to investigate are collected (EKS audit, CloudTrail,
flow logs), just not watched.

### 12. Cost-driven shortcuts

One AZ, 14-day log retention, no access logging or replication on the trail
bucket, one replica of everything, shared node group.

## Accepted scanner findings

| ID | Finding | Why it's accepted |
|----|---------|-------------------|
| A-01 | Log groups keep 14 days, not a year (Checkov CKV_AWS_338) | POC cost |
| A-02 | Trail bucket: no access logging, replication or event notifications (CKV_AWS_18, CKV_AWS_144, CKV2_AWS_62) | Needs extra buckets; out of scope |
| A-03 | Trail not copied to CloudWatch Logs, no SNS per log file (CKV2_AWS_10, CKV_AWS_252) | Alerting uses EventBridge directly |
| A-04 | Rotation Lambda: no X-Ray, no reserved concurrency, no DLQ, no code signing (CKV_AWS_50, 115, 116, 272) | No X-Ray endpoint in the VPC; reserved concurrency breaks on new accounts with a 10 limit; Secrets Manager invokes it synchronously and retries; code signing is overkill for one function |
| A-05 | cert-controller can update a secret in `external-secrets` (Trivy KSV-0113) | One secret by name, its own TLS cert |
| A-06 | cert-controller can update validating webhook configs (Trivy KSV-0114, Checkov CKV_K8S_155) | Needed to inject its CA; limited to ESO's two configs by name |
| A-07 | operator can create/update deployments (Trivy KSV-0048) | That's the role; see residual risk 1 |
| A-08 | Tunnel host has no detailed monitoring (CKV_AWS_126) | Jump box, no workload |

False positives (key policy `Resource: "*"`, endpoint policies, VPC Lambda
ENI actions, Checkov's outdated EKS version list) are suppressed inline with a
comment explaining each.

## Runbooks

The commands assume the admin role for AWS, and the SSM tunnel plus
break-glass kubeconfig from DEPLOY.md for kubectl.

### A secret value leaked (Git, a ticket, a log, a chat)

**Rotate first.** Cleaning up where it leaked comes after - by the time you've
noticed, it's been copied.

1. Rotate now:
   ```
   aws secretsmanager rotate-secret --secret-id demo/app/api-key
   aws secretsmanager describe-secret --secret-id demo/app/api-key \
     --query 'VersionIdsToStages'          # wait for a new AWSCURRENT
   ```
   For a real credential, also revoke the old one at the downstream system if
   rotation doesn't already do it.
2. Push it to the cluster instead of waiting for the hourly refresh:
   ```
   kubectl annotate externalsecret app-api-key -n demo-app force-sync=$(date +%s) --overwrite
   kubectl logs deploy/demo-app -n demo-app --tail=3   # hash prefix should change within ~2 min
   ```
3. Find out who could have used it: CloudTrail for GetSecretValue on the
   secret, EKS audit log for `get`/`list`/`watch` on `secrets` in `demo-app`
   and for `pods/exec`.
4. Then purge it from where it leaked. For Git, rewrite history with
   `git filter-repo`, force-push, ask everyone to re-clone, and ask GitHub
   support to clear cached views. The pre-commit gitleaks hook exists to make
   this rare.

### Exposed AWS credentials

1. Work out what they are from the access key ID:
   `aws sts get-access-key-info --access-key-id AKIA...` and CloudTrail
   (`userIdentity.accessKeyId`).
2. **IAM user keys:** deactivate immediately
   (`aws iam update-access-key --status Inactive ...`), then delete. There
   shouldn't be any in this design - a SecretStore with static keys is blocked.
3. **Role session credentials** (e.g. the app role from a stolen token):
   revoke all sessions issued before now. Console: IAM -> role ->
   "Revoke active sessions", which attaches a deny on `aws:TokenIssueTime`.
   New IRSA tokens keep working, so ESO recovers by itself.
4. Check CloudTrail for what the credentials did. If they could read the
   secret, follow the leaked-secret runbook too.

### Compromised ESO controller

Running pods keep working without ESO, so it's safe to stop it.

1. Stop it:
   ```
   kubectl scale deploy external-secrets -n external-secrets --replicas=0
   ```
2. Assume `demo-app` secrets are exposed: rotate them (leaked-secret runbook)
   and revoke the app role's sessions (above).
3. Look at what it did: EKS audit log entries from
   `system:serviceaccount:external-secrets:external-secrets` - token requests,
   Secret writes, anything outside `demo-app`. CloudTrail for the app role's
   calls. Flow logs for traffic from the ESO pod IP to anything but the
   endpoints.
4. Check the image digest running matches the one in `kubernetes/eso/values.yaml`
   and the one in ECR. If it doesn't, find out how it changed.
5. Re-mirror a known-good image by digest, reinstall, scale back up, force a
   sync, confirm the pod picks up the rotated value.

### GetSecretValue alert fired

The alert means someone other than the app role (via ESO) or the rotation
Lambda called GetSecretValue on a `demo/` secret. That includes denied calls.

1. Open the event from the email and note `userIdentity.arn`,
   `sourceIPAddress`, `vpcEndpointId`, `errorCode` and `eventTime`.
2. **Denied** (`AccessDenied`): someone tried. Who is it, and was it expected
   (e.g. running the V-08 check)? If not, treat the principal as compromised
   and follow the AWS credentials runbook for it.
3. **Succeeded**: the only principal that can succeed outside the allowlist is
   the admin role, and it can't decrypt, so a success should not happen. If it
   did, something in the resource policy or key policy has changed - check
   `get-resource-policy` and `get-key-policy` against Terraform, rotate, and
   revoke sessions.
4. Write down what happened and whether the allowlist needs changing.

## In production I would add

- **Multi-account structure**: workloads, security tooling, logging and shared
  services in separate accounts under AWS Organizations. The admin that runs
  a workload account shouldn't be able to touch its logs or alerts.
- **SCPs protecting the controls**, for example deny:
  `cloudtrail:StopLogging`/`DeleteTrail`, `config:StopConfigurationRecorder`/
  `DeleteConfigurationRecorder`, `guardduty:DeleteDetector`/`DisassociateFromMasterAccount`,
  `kms:ScheduleKeyDeletion`/`DisableKey` on keys tagged for EKS or secrets,
  `eks:UpdateClusterConfig` that turns on the public endpoint,
  `iam:CreateAccessKey` for workload accounts, and region restrictions.
  (EKS secrets encryption can't be removed once it's on, so there's no
  "disable encryption" call to block - protecting the key is what matters.)
- **Organization CloudTrail** into a locked-down log archive account, with
  object lock and long retention.
- **AWS Config with org-wide conformance packs** (EKS, KMS, Secrets Manager,
  EC2 IMDSv2, EBS encryption) plus a Guard rule that secrets tagged for this
  project use a CMK and have rotation on.
- **Security Hub** with FSBP and CIS standards, aggregated to the security
  account; **GuardDuty** with EKS audit log and runtime monitoring.
- **Detection**: break-glass use alarm, alerts on control changes, audit log
  queries for secret reads, exec/attach, token requests outside ESO, RBAC
  changes.
- **Cross-account secrets**: secrets live in a shared-services account; the
  secret's resource policy and the CMK's key policy grant the consuming
  account's IRSA role, conditioned on `aws:PrincipalOrgID` and the role ARN.
  No copies per account.
- **Three AZs**, endpoints in each, multiple replicas with PDBs.
- **DNS Firewall** with an allowlist of AWS domains.
- **Image signing**: verify cosign signatures before mirroring and at
  admission (e.g. Ratify with Gatekeeper).
- **CI** running the same scanners on every PR, with pinned action SHAs,
  read-only token, no secrets, never deploying.
- **Per-team node groups** (taints/tolerations) so a node compromise doesn't
  cross teams; VPC CNI network policy in strict mode.
- **Remote state** in an encrypted, versioned S3 bucket with locking and a
  bucket policy limited to the deployer role.
- **Log retention** set by the bank's retention standard, not 14 days.
