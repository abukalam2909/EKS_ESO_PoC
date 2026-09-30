# Controls

Controls **mapped to** CIS Amazon EKS Benchmark v1.8.0, AWS FSBP (Security Hub)
and NIST CSF 2.0. Mapped to, not compliant with. Threat IDs are from
[THREAT_MODEL.md](THREAT_MODEL.md); V-xx checks are in [DEPLOY.md](DEPLOY.md).

| Control | Threat | Where | CIS EKS | FSBP | CSF | Check | Status |
|---------|--------|-------|---------|------|-----|-------|--------|
| Private subnets, no NAT/internet route, VPC endpoints with account-scoped policies | T-INFO-7 | network.tf, endpoints.tf | 5.4.3 | EC2.9, EC2.15 | PR.IR | V-10 | Implemented |
| Default SG stripped, no 0.0.0.0/0 ingress, VPC flow logs | T-INFO-7 | network.tf | - | EC2.2, EC2.6 | PR.IR, DE.CM | V-10 | Implemented |
| Private API endpoint, SSM tunnel host with no SSH/public IP | T-SPOOF-2 | eks.tf, admin_host.tf | 5.4.1, 5.4.2 | EKS.1 | PR.AA | V-10 | Implemented |
| Secrets envelope-encrypted with a CMK | T-INFO-9 | eks.tf | 5.3.1 | EKS.3 | PR.DS | V-10 | Implemented |
| All control plane logs on, KMS-encrypted | T-TAMP-2 | eks.tf | 2.1.1 | EKS.8 | DE.CM | V-10 | Implemented |
| Access entries (API mode), 3 human roles, no auto cluster-admin | T-SPOOF-2 | iam_humans.tf | 4.1.7, 5.5.1 | - | PR.AA | V-10 | Implemented |
| IMDSv2, hop limit 1; minimal node role; encrypted EBS | T-INFO-4 | nodes.tf | 5.1.3 | EC2.8, EC2.3 | PR.PS | V-02 | Implemented |
| One CMK per purpose, rotation on, admins can't decrypt | T-INFO-9 | kms.tf | 5.3.1 | KMS.4, KMS.5 | PR.DS | Review | Implemented |
| Secret policy: known readers only, VPC endpoint only, admin-only policy changes | T-INFO-5, T-EXFIL-2 | secrets.tf | 4.4.2 | - | PR.AA | V-08 | Implemented |
| 30-day rotation Lambda, creates first value | T-AVAIL-1 | rotation.tf | - | SecretsManager.1, .2, .4 | PR.DS | V-09 | Implemented |
| No secret value in Terraform state or outputs | T-INFO-8 | secrets.tf | - | - | PR.DS | V-10 | Implemented |
| IRSA role trusts exact SA; reads one secret; KMS via Secrets Manager only | T-INFO-5 | iam_app.tf | 5.2.1 | KMS.1, KMS.2 | PR.AA | V-01 | Implemented |
| App pod has no AWS role; `secret-reader` runs no pods | T-INFO-5 | app/serviceaccounts.yaml | 4.1.5, 4.1.6 | - | PR.AA | V-05 | Implemented |
| ESO scoped to one namespace, no IAM role, token minting for one SA | T-INFO-6 | eso/values.yaml, eso/rbac.yaml | 4.1.2, 4.1.12 | - | PR.AA | V-07 | Implemented |
| Cluster-wide and push CRDs not installed | T-TAMP-1, T-EXFIL-1 | eso/values.yaml | - | - | PR.PS | V-07 | Implemented |
| ESO network policy: DNS, API, secrets endpoints only | T-INFO-6 | eso/networkpolicy.yaml | 4.3.2 | - | PR.IR | V-06 | Implemented |
| App namespace denies all traffic | T-INFO-7 | app/networkpolicy.yaml | 4.3.2 | - | PR.IR | V-06 | Implemented |
| Secret mounted as read-only file, never env, no subPath | T-INFO-3 | app/deployment.yaml | 4.4.1 | - | PR.DS | V-05, V-09 | Implemented |
| PSA restricted; non-root, read-only fs, limits | T-INFO-4 | namespaces.yaml | 4.2.1-4.2.5 | - | PR.PS | V-05 | Implemented |
| RBAC: no wildcards; developer view only; operator no Secret reads | T-INFO-1, T-INFO-2 | rbac.yaml | 4.1.2-4.1.4, 4.1.8 | - | PR.AA | V-03, V-04 | Partial - operator can deploy a pod that mounts the secret |
| Gatekeeper, fails closed: pod security, ECR-only images by digest | T-SUP-1 | gatekeeper/ | 4.2.1, 5.1.4 | - | PR.PS | V-05 | Implemented |
| Gatekeeper ESO rules: no cluster/push kinds or generators, no static keys, same-namespace SA, AWS only | T-SPOOF-1, T-EXFIL-1 | gatekeeper/constraints/eso.yaml | 4.5.1 | - | PR.PS | V-05 | Implemented |
| Gatekeeper: only ESO writes Secrets in demo-app; no env secrets; no subPath | T-INFO-3, T-INFO-8 | gatekeeper/constraints/app-namespace.yaml | 4.4.1 | - | PR.DS | V-05 | Implemented |
| ECR: immutable tags, scan on push, lifecycle | T-SUP-1 | ecr.tf | 5.1.1 | ECR.1, .2, .3 | GV.SC | Review | Implemented |
| CloudTrail + alert on unexpected GetSecretValue to encrypted SNS | T-REP-1 | cloudtrail.tf, detection.tf | - | CloudTrail.1, .2, .4, SNS.1 | DE.AE | V-08 | Implemented |
| gitleaks pre-commit | T-INFO-8 | .pre-commit-config.yaml | - | - | PR.DS | - | Implemented |
| ESO still reads/writes Secrets and mints one token in its namespace | T-INFO-6 | - | - | - | - | - | Accepted risk |
| Break-glass alarm, tamper alerts, audit queries, GuardDuty, Config, DNS Firewall, image signing, CI | various | - | - | - | DE.CM | - | Not implemented |

Terraform files are under `terraform/`, manifests under `kubernetes/`.
EKS.3 was retired by AWS in August 2026 (EKS encrypts by default since 1.28).
