# Threat Model: EKS Secrets Delivery with External Secrets Operator and AWS Secrets Manager

Status: Approved, with the decisions recorded in section 8.

Method: STRIDE. Each threat has a likelihood, an impact, the controls that mitigate it, how the control is verified, and the residual risk. Controls (`C-xx`) and checks (`V-xx`, `S-xx`) are catalogued at the end. CONTROLS.md, `tests/verify.sh` and CI use the same IDs.

The POC is kept deliberately small. Where a simpler option costs little security I took it and wrote the gap down as a residual risk.

---

## 1. Scope

In scope:

- One AWS account and one region (`ca-central-1`, variable).
- One VPC with a single AZ for workloads, one EKS cluster, one managed node group and one admin host reachable only through SSM.
- One application team:
  - namespace `demo-app`
  - one workload
  - one Secrets Manager secret, `demo/app/api-key`
  - one IAM role
  - one rotation Lambda
- External Secrets Operator (ESO) and OPA Gatekeeper in the cluster.
- Detection: CloudTrail, EventBridge and CloudWatch, plus GuardDuty as an option.
- Continuous compliance: AWS Config, as an option.

Out of scope, and stated in SECURITY.md:

- Multi-account structure, SCPs, organization CloudTrail and Security Hub aggregation. These are listed under "In production I would add".
- Multi-tenant isolation between teams. The same pattern would be repeated per namespace; SECURITY.md covers this.
- Application vulnerabilities in the demo workload beyond how it handles its secret.
- Compromise of AWS itself, of the EKS control plane, or of the operator's laptop.

## 2. Assets

| ID | Asset | Why it matters |
|----|-------|----------------|
| A1 | The secret value in Secrets Manager | This is what the design protects. |
| A2 | The Kubernetes Secret that ESO creates in `demo-app` | A plaintext copy. Base64 is an encoding, not encryption. |
| A3 | The secret file inside the running pod (tmpfs volume) | The final copy. Readable by the process and by anyone who can exec into the container. |
| A4 | The app's IAM role and the web identity tokens that can assume it | Anyone holding a valid token for that service account can read the secret. |
| A5 | The ESO controller | It can read and write Secrets and mint service account tokens in `demo-app`. |
| A6 | KMS keys (EKS secrets, Secrets Manager, logs) | Deleting or disabling a key breaks every consumer. Changing a key policy can widen access. |
| A7 | Audit and detection data (EKS audit log, CloudTrail, Flow Logs) | Without it, misuse cannot be detected or investigated. |
| A8 | Security configuration (Gatekeeper constraints, NetworkPolicies, PSA labels, RBAC, resource policy, Config rules) | If this drifts or is disabled, every other control weakens. |
| A9 | Terraform state, the Git repository and CI logs | Common places where secrets leak by accident. |

## 3. Actors

| Actor | Legitimate access | Assumed intent in this model |
|-------|-------------------|------------------------------|
| Read-only developer (IAM role, access entry) | View pods, deployments and logs in `demo-app` | Curious or careless, or holding stolen credentials |
| Platform operator (IAM role, access entry) | Manage SecretStore, ExternalSecret and Deployments | Trusted but fallible. The main indirect path to the secret. |
| Break-glass admin (IAM role, access entry) | cluster-admin | Emergency use only. Every use triggers an alert. |
| Compromised workload pod | Its own mounted secret file | An attacker with code execution in the container |
| Compromised ESO controller | Its RBAC and its network egress | Code execution in the controller, or a malicious upstream image |
| Compromised node | Kubelet credentials and the node IAM role | Largely out of reach of these controls. Treated as residual risk. |
| External attacker | None | Internet-based. Uses stolen AWS credentials. |
| Malicious or vulnerable upstream (images, charts, Actions) | Whatever runs in the cluster or in CI | Supply chain |

## 4. Trust boundaries

1. Internet and AWS account. There is no inbound path and, with NAT off, no outbound path.
2. VPC and AWS APIs. Traffic goes through interface endpoints, which have endpoint policies.
3. Kubernetes API and the `demo-app` namespace. Enforced by RBAC, Gatekeeper and Pod Security Admission (PSA).
4. Between namespaces (`demo-app`, `external-secrets`, `gatekeeper-system`, and others). Enforced by NetworkPolicy, RBAC and the IAM trust policy.
5. Pod and node. Enforced by PSA restricted and an IMDS hop limit of 1.
6. Human and cluster. Access goes through SSM Session Manager to the admin host, then to the private API endpoint, using an IAM role and an access entry.

## 5. Design notes

1. **ESO can be scoped to one namespace, and with one team that fits exactly.** The chart setting `scopedNamespace: demo-app` with `scopedRBAC: true` gives the controller Roles in `demo-app` only. With the chart defaults it would instead get a ClusterRole that can read and write Secrets and mint tokens in every namespace, including `kube-system`.
2. **The risky custom resources can be left uninstalled.** The chart flags `crds.createClusterSecretStore`, `crds.createClusterExternalSecret`, `crds.createPushSecret` and `crds.createClusterPushSecret` can all be false, together with the matching `process*` flags. Those kinds then do not exist in the API. Gatekeeper still denies them as a second layer, in case a later chart upgrade reinstalls them.
3. **ESO has exfiltration paths other than PushSecret.** A SecretStore using the Webhook provider (or other providers) can send in-cluster data to any URL, and so can the Webhook generator. Gatekeeper therefore allows only `provider.aws` with `service: SecretsManager`, and the Generator CRDs are not installed or are denied.
4. **An IRSA-annotated workload service account gives the app pod AWS credentials it does not need.** The pod identity webhook injects a web identity token into every pod that runs as an annotated service account. So there are two service accounts:
   - `secret-reader`: has the annotation, runs no pods, and is referenced only by the SecretStore.
   - `app`: no annotation. The workload runs as this account.

   Gatekeeper denies any pod that uses `secret-reader`.
5. **The GetSecretValue alert needs a trail.** GetSecretValue is a read-only management event. It reaches EventBridge only if a CloudTrail trail exists and the rule state is `ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS`. This is to be verified in Step 2. A trail is added: management events only, a KMS-encrypted S3 bucket, and log file validation.
6. **A private cluster without NAT needs extra VPC endpoints.** It needs an `ec2` endpoint for the VPC CNI, and possibly `eks` and `eks-auth`; the list is to be verified against the EKS private cluster documentation. Images that are not hosted in ECR (ESO, Gatekeeper and the workload) must be copied into private ECR from the laptop first.
7. **Gatekeeper fails open by default.** Its webhook uses `failurePolicy: Ignore`, so the POC changes this (D5).
8. **DNS can still carry data out with no internet route.** CoreDNS forwards to the Route 53 Resolver, which resolves public names, so DNS tunnelling is possible. DNS Firewall would close this, but it is not implemented in the POC (D6).
9. **The customer-managed key adds control, not encryption itself.** EKS already envelope-encrypts Kubernetes API data with an AWS-owned key on current versions; the exact version is to be verified. The customer-managed key adds control over the key policy, a CloudTrail record of every Decrypt, and the ability to revoke access. The README says this accurately.
10. **A subPath mount never receives rotated values.** Kubelet does not update files mounted with `subPath`, so Gatekeeper denies subPath mounts of Secret volumes.

## 6. Rating scale

Ratings are inherent, meaning they assume the planned controls are absent, in a regulated bank context.

- **Likelihood:**
  - High: routine, or a known frequent mistake.
  - Medium: needs a foothold or a specific misconfiguration.
  - Low: needs a hardened component to be compromised.
- **Impact:**
  - High: secret disclosure or loss of audit.
  - Medium: a limited disclosure path, or degraded detection or availability.
  - Low: a nuisance.

## 7. Threats

### Information disclosure

#### T-INFO-1: A developer reads the ESO-created Kubernetes Secret through the API
- **Scenario:** A developer runs `kubectl get secret -o yaml`, or uses list or watch, which also return the data, and then decodes the base64.
- **STRIDE:** I. **Likelihood:** High. **Impact:** High.
- **Controls:**
  - C-RBAC-1: the developer has no get, list or watch on Secrets.
  - C-RBAC-2: no wildcards in any Role or ClusterRole.
  - C-RBAC-3: no impersonate, escalate or bind for non-admin roles.
  - C-DET-3: an audit log query finds Secret reads by anyone other than ESO.
- **Verified by:** V-03, S-01.
- **Residual:** Break-glass, the ESO controller and the kubelet on the pod's node can still read the Secret. This is inherent to Kubernetes Secrets.

#### T-INFO-2: Indirect read by creating a pod that mounts the Secret, or by exec or attach
- **Scenario:** Anyone who can create a pod, or a Deployment, Job or other workload controller, can mount the Secret. Exec, attach and ephemeral debug containers expose the mounted file directly.
- **STRIDE:** I, E. **Likelihood:** High. **Impact:** High.
- **Controls:**
  - C-RBAC-1: the developer cannot create pods or workload controllers, and has no `pods/exec`, `pods/attach`, `pods/ephemeralcontainers` or `pods/portforward`.
  - C-RBAC-4: the operator's ability to deploy workloads is documented as equivalent to reading the secret.
  - C-GK-3: no pod may run as `secret-reader`.
  - C-DET-3: an audit log query finds exec and attach.
- **Verified by:** V-03, V-04.
- **Residual:** The operator, and any CI/CD in production, can always obtain the value. SECURITY.md states this.

#### T-INFO-3: The secret is exposed through environment variables
- **Scenario:** An environment variable leaks through `/proc/<pid>/environ`, `kubectl describe`, crash dumps, debug endpoints and child processes, and it never updates on rotation.
- **STRIDE:** I. **Likelihood:** High. **Impact:** Medium to High.
- **Controls:**
  - C-WL-1: the secret is a read-only volume with mode 0400.
  - C-GK-8: deny `secretKeyRef` and `envFrom.secretRef` in `demo-app`.
  - C-WL-2: the app reads the file on each use and logs only a hash prefix.
- **Verified by:** V-05, S-01.
- **Residual:** The value is still in process memory and in a file readable by the container user.

#### T-INFO-4: A compromised pod steals node IAM credentials through IMDS
- **STRIDE:** I, E. **Likelihood:** Medium. **Impact:** Medium. The node role has no Secrets Manager access.
- **Controls:**
  - C-NODE-1: IMDSv2 is required with hop limit 1.
  - C-NET-1: default-deny egress.
  - C-PSA-1: PSA restricted blocks `hostNetwork`.
  - C-NODE-2: the node role has only the AWS-managed policies EKS requires.
- **Verified by:** V-02.
- **Residual:** A node compromise yields the node credentials anyway.

#### T-INFO-5: Another namespace or service account uses the app's identity or secret
- **Scenario:**
  - A SecretStore in another namespace references `demo-app:secret-reader`.
  - A different service account tries to assume the app role.
  - A SecretStore references a secret outside `demo/app/*`.
- **STRIDE:** S, I, E. **Likelihood:** Medium. **Impact:** High.
- **Controls:**
  - C-IAM-1: the trust policy matches the exact `sub` (`system:serviceaccount:demo-app:secret-reader`) and `aud` (`sts.amazonaws.com`).
  - C-IAM-2: the permission policy covers only the one secret ARN. `kms:Decrypt` is limited by `kms:ViaService` and `kms:EncryptionContext:SecretARN`.
  - C-SM-1: the secret's resource policy denies every principal except the app role, the rotation Lambda and the admin ARN.
  - C-GK-6: deny a serviceAccountRef that points to another namespace.
  - C-ESO-1: only namespaced SecretStores exist.
  - C-ESO-2: the controller is scoped to `demo-app` only.
- **Verified by:** V-01 (a token for `demo-app:app` cannot assume the role, and the role is denied an ARN outside its scope), V-05.
- **Residual:** Break-glass and the ESO controller can mint a `secret-reader` token.

#### T-INFO-6: The ESO controller is compromised
- **Scenario:** Code execution or a malicious image in the controller. The controller can read and write Secrets and mint tokens.
- **STRIDE:** I, E, T. **Likelihood:** Low. **Impact:** High.
- **Controls:**
  - C-ESO-2: scoped RBAC, so there is no access outside `demo-app`.
  - C-ESO-3: no IAM role on the controller service account.
  - C-ESO-4: egress only to DNS, the API server and the STS and Secrets Manager endpoints.
  - C-ESO-5: non-root, read-only root filesystem, all capabilities dropped, seccomp, resource limits, and PSA restricted.
  - C-SUP-1: the image is pinned by digest and scanned.
  - C-ESO-6: `serviceaccounts/token` is restricted by `resourceNames` to `secret-reader`. The chart setting `rbac.serviceAccountTokenCreate: false` drops the broad grant, and the repository adds a narrow Role instead.
  - C-DET-3: an audit log query finds token requests.
- **Verified by:** V-06, V-07.
- **Residual:** Inside `demo-app`, the controller can read and write every Secret and mint a `secret-reader` token, so it can read the AWS secret. This is ESO's function and cannot be removed. SECURITY.md documents it.

#### T-INFO-7: The secret is exfiltrated over the internet
- **STRIDE:** I. **Likelihood:** Medium. **Impact:** High.
- **Controls:**
  - C-NET-2: no NAT and no internet route, so there is no IP path out.
  - C-NET-1 and C-ESO-4: default-deny egress.
  - C-NET-3: endpoint policies are limited to this account's principals and resources.
  - C-DET-6: VPC Flow Logs.
- **Verified by:** V-06, V-10.
- **Residual:** DNS tunnelling (D6), and anything allowed through the endpoints to resources in this account.

#### T-INFO-8: Secrets leak through Git, Terraform state, logs or CI
- **STRIDE:** I. **Likelihood:** High. **Impact:** High.
- **Controls:**
  - C-GIT-1: gitleaks runs as a pre-commit hook and in CI.
  - C-TF-1: Terraform creates the secret container only. There is no `secret_version` resource, and the first value comes from the rotation Lambda.
  - C-TF-2: no outputs carry secrets.
  - C-TEST-1: checks print only 12-character hash prefixes.
  - C-WL-2: the app logs only a hash prefix.
  - C-CI-1: CI has no secrets, a read-only token, and does not deploy.
- **Verified by:** V-10 (the state contains no secret version), S-02.
- **Residual:** A human who is allowed to call GetSecretValue can copy the value.

#### T-INFO-9: Secret data is exposed from etcd or backups
- **STRIDE:** I. **Likelihood:** Low. **Impact:** High.
- **Controls:**
  - C-EKS-2: envelope encryption with a customer-managed key.
  - C-CFG-1: a Config rule checks it.
  - No cluster backup tool is installed.
- **Verified by:** V-10, V-11.
- **Residual:** None for the API path; encryption at rest does not protect against anyone authorized to read Secrets through the API.

### Spoofing and repudiation

#### T-SPOOF-1: A SecretStore uses static AWS access keys
- **STRIDE:** S, I. **Likelihood:** Medium. **Impact:** High.
- **Controls:**
  - C-GK-5: deny `auth.secretRef`. Only `auth.jwt.serviceAccountRef` is allowed.
  - C-GK-7: manual Secret creation in `demo-app` is denied, so there is nowhere to store a key.
  - C-SM-2: requests from outside the VPC endpoint are denied.
- **Verified by:** V-05, V-08.
- **Residual:** Nothing in the account prevents IAM users with access keys from being created. That needs an SCP in production.

#### T-SPOOF-2: The break-glass role is used quietly
- **STRIDE:** S, R. **Likelihood:** Medium. **Impact:** Medium.
- **Controls:**
  - C-EKS-4: access entries give each of the three roles its own identity.
  - C-DET-2: a metric filter and alarm fire on break-glass use.
  - C-EKS-3: the authenticator log records the IAM ARN.
- **Verified by:** V-11 (`aws logs test-metric-filter` against a sample event).
- **Residual:** Use is detected, not prevented. This is deliberate.

#### T-REP-1: Misuse of GetSecretValue goes undetected
- **STRIDE:** R, I. **Likelihood:** Medium. **Impact:** High.
- **Controls:**
  - C-DET-0: a CloudTrail trail.
  - C-DET-1: an EventBridge rule matches GetSecretValue on the demo secret from any principal outside the allowlist (the app role and the rotation Lambda), including denied calls, and sends it to an encrypted SNS topic.
  - C-DET-5: GuardDuty, as an option.
- **Verified by:** V-08. A denied call from the laptop must increase the rule's `MatchedEvents` metric.
- **Residual:** Alert delivery takes minutes. Reads by allowlisted roles are not alerted, by design.

### Tampering and elevation

#### T-TAMP-1: A ClusterSecretStore or ClusterExternalSecret is used to cross namespace boundaries
- **STRIDE:** T, E. **Likelihood:** Medium. **Impact:** High.
- **Controls:**
  - C-ESO-1: these CRDs are not installed, and the `process*` flags are off.
  - C-GK-4: a Gatekeeper deny, as a second layer.
  - C-DET-3: an audit log query finds these kinds.
- **Verified by:** V-05 and V-07. A "no matches for kind" error counts as a pass.
- **Residual:** Break-glass could reinstall the CRDs, and that would be visible in the audit log.

#### T-EXFIL-1: PushSecret, a non-AWS provider, or a Generator is used to exfiltrate data
- **STRIDE:** I. **Likelihood:** Low to Medium. **Impact:** High.
- **Controls:**
  - C-ESO-1 and C-ESO-8: the push and generator CRDs are not installed, or are denied.
  - C-GK-4: Gatekeeper denies these kinds.
  - C-GK-10: a SecretStore must use AWS Secrets Manager in the cluster's region.
  - C-IAM-2: the app role has no `PutSecretValue` or `CreateSecret`.
  - C-ESO-4: controller egress is limited.
- **Verified by:** V-05, V-07.
- **Residual:** None known.

#### T-EXFIL-2: Stolen role credentials are used from outside the VPC
- **STRIDE:** S, I. **Likelihood:** Medium. **Impact:** High.
- **Controls:**
  - C-SM-2: the resource policy denies any request where `aws:SourceVpce` is not this endpoint. The exceptions are the admin ARN, to avoid lockout, and AWS service principals only if rotation needs them (to be verified).
  - C-DET-1: the GetSecretValue alert.
- **Verified by:** V-08 (a call from the laptop is denied).
- **Residual:** Stolen admin credentials work from anywhere, and the alert covers that case. If the endpoint is deleted, only the admin can recover. This is commented in the code.

#### T-TAMP-2: Security controls are disabled or drift
- **Scenario:**
  - Logging is turned off.
  - Encryption is missing on a rebuilt cluster.
  - Key rotation is disabled, or key deletion is scheduled.
  - The resource policy is removed.
  - Flow logs are deleted.
  - A Gatekeeper constraint is deleted, or Gatekeeper fails open.
  - PSA labels are removed.
- **STRIDE:** T, R. **Likelihood:** Medium. **Impact:** High.
- **Controls:**
  - C-CFG-1: AWS Config rules, as an option.
  - C-DET-4: an EventBridge rule sends high-risk API calls to SNS: `ScheduleKeyDeletion`, `DisableKey`, `DisableKeyRotation`, `PutKeyPolicy`, `DeleteResourcePolicy`, `PutResourcePolicy`, `UpdateClusterConfig`, `DeleteFlowLogs`, `StopLogging`, `DeleteTrail`, `DeleteLogGroup` and `CancelRotateSecret`.
  - C-DET-3: audit log queries for RBAC, constraint and webhook changes.
  - C-GK-9: Gatekeeper uses `failurePolicy: Fail`.
  - C-PSA-1: PSA works independently of Gatekeeper.
  - C-RBAC-5: only break-glass can change constraints, webhooks or namespace labels.
- **Verified by:** V-09 (`aws events test-event-pattern` against sample events; nothing is disabled), V-11, V-05 (checks the webhook failurePolicy).
- **Residual:** In a single account, an account admin can also disable the detection. SCPs and a separate security account are the production answer.

#### T-TAMP-3: An ExternalSecret is pointed at an existing Secret
- **STRIDE:** T. **Likelihood:** Low. **Impact:** Medium.
- **Controls:** C-ESO-7 (`creationPolicy: Owner` means ESO will not adopt a Secret it does not own).
- **Verified by:** Review only.
- **Residual:** The operator can repoint the app's own ExternalSecret. That is intended.

### Availability and staleness

#### T-AVAIL-1: The secret is never rotated, or rotation never reaches the pod
- **STRIDE:** I, D. **Likelihood:** High. **Impact:** Medium.
- **Controls:**
  - C-SM-3: 30-day rotation by a Lambda.
  - C-ESO-7: `refreshInterval` is 1h.
  - C-WL-1: the secret is a volume, with no subPath.
  - C-WL-2: the app re-reads the file on each use.
  - C-CFG-1: rotation Config rules.
- **Verified by:** V-09. The check forces rotation and a sync, then compares hash prefixes of the Kubernetes Secret and of the pod file.
- **Residual:**
  - Worst-case propagation is the refresh interval plus the kubelet sync period and cache TTL, about 1h plus 1 to 2 minutes.
  - The value is synthetic. `setSecret` does nothing because there is no downstream system, and `testSecret` only validates the format. This is stated plainly.

#### T-AVAIL-2: Secrets Manager, STS or ESO is unavailable, or a KMS key is deleted
- **STRIDE:** D. **Likelihood:** Low. **Impact:** Medium, or High if a key is deleted.
- **Controls:**
  - The Kubernetes Secret persists, so running and new pods keep the last value.
  - `deletionPolicy: Retain` (D8).
  - KMS keys have a 7-day deletion window, and C-DET-4 alerts on `ScheduleKeyDeletion`.
- **Verified by:** Failure modes are documented in the README and are not tested destructively.
- **Residual:** Losing the EKS secrets key makes the cluster's Secrets unreadable.

### Supply chain

#### T-SUP-1: A malicious or vulnerable container image, including ESO
- **STRIDE:** T, E. **Likelihood:** Medium. **Impact:** High.
- **Controls:**
  - C-SUP-1: images are pinned by digest and mirrored into private ECR.
  - C-GK-2: images are allowed only from this account's ECR, and only with a digest.
  - C-SUP-2: Trivy scans, and ECR scans on push.
  - C-SUP-3: cosign verification before mirroring, where upstream signs images (to be verified).
  - C-SUP-4: Actions are pinned to SHAs, and Dependabot is enabled.
  - C-PSA-1: PSA restricted.
- **Verified by:** V-05 (an unpinned image is rejected), S-03.
- **Residual:** Pinning trusts whatever was pinned, and zero-days are not prevented.

#### T-SUP-2: The rotation Lambda is compromised or over-privileged
- **STRIDE:** E, I. **Likelihood:** Low. **Impact:** High.
- **Controls:** C-SM-4:
  - The Lambda can act on the one secret ARN only.
  - It generates values with `GetRandomPassword`.
  - It runs in the VPC, with egress only to the Secrets Manager endpoint.
  - Its logs are encrypted with the logs key.
  - It uses no third-party layers.
- **Verified by:** S-01 (policy review through Checkov), and review.
- **Residual:** The Lambda can read and write the secret by design.

## 8. Decisions (agreed)

| ID | Decision | Outcome |
|----|----------|---------|
| D1 | ESO topology | One controller with `scopedNamespace: demo-app` and `scopedRBAC: true`. There is no cluster-wide access. |
| D2 | Egress | No NAT gateway. Images and Helm charts are copied into private ECR from the laptop, and admin tools are staged through S3. `enable_nat` stays as a flag, off by default, as a simpler but weaker fallback. |
| D3 | Service accounts | `secret-reader` has the IRSA annotation and runs no pods. `app` has no AWS access. |
| D4 | Availability zones | Single AZ for nodes, the admin host and all endpoints. EKS requires control plane subnets in two AZs, so a second small subnet exists only for control plane network interfaces. There is no zone redundancy, which is accepted for a POC. |
| D5 | Gatekeeper failure policy | Fail closed, with `kube-system` and `gatekeeper-system` exempted. DEPLOY.md includes the recovery step. |
| D6 | DNS Firewall | Not implemented. Documented as residual risk and as a production addition. |
| D7 | Node isolation | A shared node group is used. It is not a concern with one team, but it would matter with several. |
| D8 | ExternalSecret `deletionPolicy` | `Retain`. A provider-side deletion or outage does not remove the in-cluster Secret and take the app down. Revocation is done by rotating. |
| D9 | Verification | A single `tests/verify.sh` with checks V-01 to V-11 prints PASS or FAIL and a summary. Static checks S-01 to S-03 run in pre-commit and CI. There is no `scripts/` folder; deploy commands are written inline in DEPLOY.md. |

## 9. Control catalogue (planned)

| ID | Control |
|----|---------|
| C-NET-1 | Default-deny ingress and egress NetworkPolicy in `demo-app` |
| C-NET-2 | Private subnets, no public IPs, no NAT by default |
| C-NET-3 | Interface and gateway endpoints with account-scoped endpoint policies |
| C-NET-4 | Security groups with no ingress from 0.0.0.0/0; endpoints in a dedicated subnet so NetworkPolicy can target them by CIDR |
| C-EKS-1 | Private API endpoint only; admin host reachable only through SSM (IMDSv2, encrypted volume, no key pair) |
| C-EKS-2 | Envelope encryption of Secrets with a customer-managed key |
| C-EKS-3 | All five control plane log types sent to a KMS-encrypted log group |
| C-EKS-4 | Access entries (API mode) for the break-glass, operator and developer roles |
| C-NODE-1 | IMDSv2 required, hop limit 1 |
| C-NODE-2 | Node role limited to the AWS-managed policies EKS requires; EBS encrypted with a customer-managed key |
| C-KMS-1 | Three separate customer-managed keys, rotation on, 7-day deletion window, key administrators separate from key users |
| C-SM-1 | Resource policy denying everyone except the app role, the Lambda and the admin |
| C-SM-2 | Resource policy deny for requests outside `aws:SourceVpce`, with reasoned exceptions |
| C-SM-3 | 30-day rotation |
| C-SM-4 | Least-privilege rotation Lambda running in the VPC |
| C-IAM-1 | IRSA trust policy scoped to the exact `sub` and `aud` |
| C-IAM-2 | Permission policy covering one secret ARN, with KMS limited by `kms:ViaService` and `kms:EncryptionContext:SecretARN` |
| C-ESO-1 | Cluster-scoped and push CRDs not installed; `process*` flags off |
| C-ESO-2 | Controller scoped to `demo-app` (`scopedNamespace`, `scopedRBAC`) |
| C-ESO-3 | No IAM role on the ESO service account |
| C-ESO-4 | ESO NetworkPolicy: egress to DNS, the API server and the endpoint subnet only; webhook ingress from the control plane only |
| C-ESO-5 | ESO pod hardening; PSA restricted on its namespace |
| C-ESO-6 | Token minting limited to `secret-reader` (`rbac.serviceAccountTokenCreate: false` plus a Role that uses `resourceNames`) |
| C-ESO-7 | `refreshInterval` 1h, `creationPolicy: Owner`, `deletionPolicy: Retain` |
| C-ESO-8 | Generator kinds disabled or denied |
| C-WL-1 | Secret mounted as a read-only volume, mode 0400, no subPath |
| C-WL-2 | App re-reads the file on each use and logs only a hash prefix |
| C-WL-3 | `automountServiceAccountToken: false`; non-root, read-only root filesystem, all capabilities dropped, seccomp, resource limits; image pinned by digest |
| C-PSA-1 | PSA restricted enforced on `demo-app` and `external-secrets` |
| C-RBAC-1 | Developer: view only (no Secrets, pod creation, exec or attach, ESO resources or RBAC) |
| C-RBAC-2 | No wildcards in any Role or ClusterRole |
| C-RBAC-3 | No impersonate, escalate or bind for non-admin roles |
| C-RBAC-4 | Operator: manages ExternalSecret, SecretStore and Deployments; no Secret reads (indirect access is documented) |
| C-RBAC-5 | Only break-glass can change constraints, webhooks or namespace labels |
| C-GK-1 | No privileged containers or privilege escalation; runAsNonRoot required; resource limits required |
| C-GK-2 | Images from allowed registries only, pinned by digest |
| C-GK-3 | No pod may run as `secret-reader` |
| C-GK-4 | Deny ClusterSecretStore, ClusterExternalSecret, PushSecret and ClusterPushSecret |
| C-GK-5 | Deny a SecretStore that uses `auth.secretRef` (static keys) |
| C-GK-6 | Deny a serviceAccountRef that points to another namespace |
| C-GK-7 | Deny Secret create or update in `demo-app` by anyone except the ESO service account |
| C-GK-8 | Deny Secret references through env or envFrom in `demo-app` |
| C-GK-9 | Gatekeeper `failurePolicy: Fail`; rollout in dryrun first, then deny |
| C-GK-10 | SecretStore provider limited to AWS Secrets Manager in the cluster's region |
| C-GK-11 | Deny subPath mounts of Secret volumes |
| C-DET-0 | CloudTrail trail (management events, KMS encryption, log file validation) |
| C-DET-1 | GetSecretValue alert for principals outside the allowlist, sent to encrypted SNS |
| C-DET-2 | Break-glass metric filter and alarm |
| C-DET-3 | Saved Logs Insights queries on the EKS audit log |
| C-DET-4 | Alert on API calls that disable controls |
| C-DET-5 | GuardDuty EKS protection and optional Runtime Monitoring (flag) |
| C-DET-6 | VPC Flow Logs, KMS-encrypted, short retention |
| C-CFG-1 | AWS Config recorder, managed rules and a custom Guard rule (flag) |
| C-TF-1 | No secret values in Terraform |
| C-TF-2 | No outputs that carry secrets |
| C-GIT-1 | gitleaks in pre-commit and CI |
| C-CI-1 | CI hardening: SHA pins, read-only token, no `pull_request_target`, no secrets, no deploy |
| C-SUP-1 | Images pinned by digest and mirrored into private ECR |
| C-SUP-2 | Trivy and ECR image scanning |
| C-SUP-3 | Signature verification where upstream signs images |
| C-SUP-4 | Actions pinned to SHAs; Dependabot |
| C-TEST-1 | Checks print hash prefixes only, never values |

## 10. Verification catalogue (planned)

Runtime checks are functions in `tests/verify.sh`. Each prints PASS or FAIL, and the script ends with a summary table. Static checks run in pre-commit and CI.

| ID | Check | Where it runs |
|----|-------|---------------|
| V-01 | A token for `demo-app:app` cannot assume the app role; the app role is denied any ARN outside `demo/app/*` | Admin host |
| V-02 | A pod cannot get node credentials from IMDS | Admin host |
| V-03 | The developer is denied: Secret get, list and watch; creating pods or workloads; exec, attach and ephemeral containers; creating SecretStore or ExternalSecret; RBAC changes | Admin host |
| V-04 | The operator can manage ExternalSecret but cannot get Secrets | Admin host |
| V-05 | Gatekeeper rejects each object in `tests/fixtures/` (server-side dry run, so nothing is created), and the webhook failurePolicy is Fail | Admin host |
| V-06 | NetworkPolicy blocks cross-namespace traffic, egress from `demo-app`, and ESO egress to destinations that are not allowed | Admin host |
| V-07 | The ESO service account has no role annotation and the controller pod has no AWS credentials; the cluster and push CRDs are absent; the ESO service account is denied outside `demo-app` | Admin host |
| V-08 | GetSecretValue from outside the VPC endpoint is denied, and the alert's `MatchedEvents` metric increases | Laptop |
| V-09 | Forced rotation reaches the Kubernetes Secret and the pod file within the bound (hash prefixes only); tamper-event patterns match sample events | Admin host |
| V-10 | Cluster and network posture: private endpoint, encryption key, log types, access entry mode, no route to 0.0.0.0/0; Terraform state holds no secret version | Laptop |
| V-11 | AWS Config rules report COMPLIANT (if enabled); the break-glass metric filter matches a sample event | Laptop |
| S-01 | Checkov, Trivy config, tflint, kubeconform, kube-linter, and a check that RBAC has no wildcards | Pre-commit and CI |
| S-02 | gitleaks | Pre-commit and CI |
| S-03 | Trivy image scan; kube-bench (EKS profile) and kubescape (CIS, NSA) run from the admin host, with results in `evidence/` | CI and admin host |

## 11. Residual risk summary

These carry over into SECURITY.md.

1. A Kubernetes Secret exists. Break-glass, the ESO controller, the operator (indirectly) and the kubelet on the pod's node can read it.
2. The ESO controller keeps read and write access to Secrets, and the ability to mint the `secret-reader` token, in `demo-app`.
3. A node compromise exposes the tokens and Secrets of every pod on that node.
4. Break-glass is all-powerful. Its use is detected, not prevented.
5. In a single account, an account admin can disable detection and compliance controls.
6. DNS exfiltration is possible, because DNS Firewall is not implemented.
7. The admin ARN exception in the resource policy works from outside the VPC endpoint.
8. Rotation is demonstrated on a synthetic value. Real credential rotation needs a `setSecret` step against the downstream system.
9. Cost-driven compromises: a single AZ, optional Config and GuardDuty, no DNS Firewall.
