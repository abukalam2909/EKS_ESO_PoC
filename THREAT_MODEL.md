# Threat model

STRIDE, for one app team (`demo-app`) on a private EKS cluster pulling one
secret (`demo/app/api-key`) from Secrets Manager through ESO. Controls are in
[CONTROLS.md](CONTROLS.md), checks (V-xx) in [DEPLOY.md](DEPLOY.md), residual
risks in [SECURITY.md](SECURITY.md).

## What's being protected

- the secret value in Secrets Manager
- the Kubernetes Secret ESO creates (base64 is not encryption)
- the mounted file in the app pod
- the app's IAM role and the tokens that can assume it
- the ESO controller (reads/writes Secrets, mints tokens)
- KMS keys, audit logs, and the security config itself (RBAC, Gatekeeper,
  network policies, resource policies)
- Git, Terraform state and logs, where secrets usually leak

## Who

Developer (read-only), platform operator (deploys, manages ESO resources),
break-glass admin, a compromised app pod, a compromised ESO controller, a
compromised node, an outsider with stolen AWS credentials, and a bad upstream
image.

## Trust boundaries

Internet / AWS account · VPC / AWS APIs (endpoints) · Kubernetes API /
namespaces (RBAC, Gatekeeper, PSA) · namespace / namespace (network policy,
IAM trust) · pod / node (PSA, IMDS hop limit) · human / cluster (SSM tunnel,
access entries).

## Threats

L = likelihood, I = impact (H/M/L, before controls).

| ID | Threat | STRIDE | L | I | Main controls | Check | Residual |
|----|--------|--------|---|---|---------------|-------|----------|
| T-INFO-1 | Developer reads the Kubernetes Secret via the API | I | H | H | No secret get/list/watch in any non-admin role, no wildcards | V-03 | Break-glass, ESO, kubelet can still read it |
| T-INFO-2 | Someone creates a pod that mounts the Secret, or execs into the app | I, E | H | H | Developer can't create pods/workloads or exec; no pods as `secret-reader` | V-03, V-05 | Operator can deploy a pod that mounts it |
| T-INFO-3 | Secret leaks through env vars (proc, dumps, logs), never updates | I | H | M | Mounted as read-only file; Gatekeeper denies env/envFrom | V-05 | Value is in the app's memory and file |
| T-INFO-4 | Pod steals node credentials via IMDS | I, E | M | M | IMDSv2 hop limit 1, default-deny egress, PSA blocks hostNetwork | V-02 | Node compromise gets them anyway |
| T-INFO-5 | Another namespace or SA uses the app's identity or secret | S, I | M | H | IRSA trust on exact SA; role reads one secret; secret policy; same-namespace SA rule | V-01, V-05 | ESO and break-glass can mint the token |
| T-INFO-6 | ESO controller compromised | I, E | L | H | Scoped to one namespace, no IAM role, token minting for one SA, network policy, hardened pod | V-06, V-07 | It still owns `demo-app`'s secrets |
| T-INFO-7 | Secret sent out over the internet | I | M | H | No NAT/internet route, default-deny egress, endpoint policies, flow logs | V-06, V-10 | DNS tunnelling |
| T-INFO-8 | Secret in Git, Terraform state, logs or CI | I | H | H | gitleaks hook; Terraform never writes a value; app logs a hash only | V-10 | A human who can read it can copy it |
| T-INFO-9 | etcd or backup exposure | I | L | H | Envelope encryption with a CMK | V-10 | Doesn't help against API readers |
| T-SPOOF-1 | SecretStore with static AWS keys | S | M | H | Gatekeeper denies `auth.secretRef`; only ESO can write Secrets; VPC-endpoint-only secret | V-05, V-08 | Account can still create IAM keys (SCP in prod) |
| T-SPOOF-2 | Break-glass or human actions not attributable | S, R | M | M | Access entries with per-role usernames, audit logs | V-10 | Not alerted on |
| T-REP-1 | Misuse of GetSecretValue goes unnoticed | R | M | H | CloudTrail + EventBridge alert for anyone but ESO's role and the rotation Lambda | V-08 | Minutes of delay |
| T-TAMP-1 | ClusterSecretStore / ClusterExternalSecret crossing namespaces | T, E | M | H | CRDs not installed; Gatekeeper denies them | V-05, V-07 | Break-glass could reinstall |
| T-TAMP-2 | Controls disabled or drifting (logging, keys, Gatekeeper) | T | M | H | Gatekeeper fails closed; PSA as a second layer; only break-glass can change policy | V-05 | No tamper alerts, no Config |
| T-TAMP-3 | ExternalSecret pointed at an existing Secret | T | L | M | `creationPolicy: Owner` | - | - |
| T-EXFIL-1 | PushSecret, generators or a webhook provider used to exfiltrate | I | L | H | CRDs not installed / denied; stores must be AWS Secrets Manager | V-05 | - |
| T-EXFIL-2 | Stolen role credentials used from outside the VPC | S, I | M | H | Secret policy denies calls not through the VPC endpoint; alert | V-08 | Admin is exempt (can't decrypt though) |
| T-AVAIL-1 | Secret never rotated, or rotation never reaches the pod | I, D | H | M | 30-day rotation, 1h refresh, file mount, no subPath, app re-reads | V-09 | Up to ~1h delay |
| T-AVAIL-2 | Secrets Manager/STS/ESO down, or a key deleted | D | L | M | Last Secret stays (`Retain`), 7-day key deletion window | - | Deleting the EKS key is unrecoverable |
| T-SUP-1 | Bad or vulnerable image, including ESO | T, E | M | H | Digest pins, ECR-only, scan on push, PSA restricted | V-05 | Signatures not verified |
| T-SUP-2 | Rotation Lambda over-privileged | E | L | H | One secret only, in the VPC, egress to one endpoint | - | Can read its secret by design |

## Decisions

| | Decision |
|--|----------|
| D1 | One ESO controller scoped to `demo-app` (`scopedNamespace`, `scopedRBAC`) |
| D2 | No NAT; images mirrored to ECR; NAT only as an off-by-default flag |
| D3 | Two SAs: `secret-reader` (IRSA, no pods) and `app` (no AWS access) |
| D4 | Single AZ; second AZ only for the control plane subnet EKS requires |
| D5 | Gatekeeper fails closed, system namespaces exempt |
| D6 | No DNS Firewall |
| D7 | Shared node group |
| D8 | ExternalSecret `deletionPolicy: Retain` |
| D9 | Verification is manual (DEPLOY.md), no test suite in the repo |
| D10 | Detection limited to the GetSecretValue alert; no break-glass alarm, tamper alerts, GuardDuty or Config |
