# 0002 - External Secrets Operator over the Secrets Store CSI Driver

Status: accepted

## Context

Two common ways to get Secrets Manager values into pods on EKS:

- **External Secrets Operator** - a controller syncs the value into a normal
  Kubernetes Secret; pods consume the Secret as usual.
- **Secrets Store CSI Driver + AWS provider (ASCP)** - a CSI volume fetches the
  value at pod start, using the pod's own identity, and mounts it straight
  into the pod. A Kubernetes Secret is only created if you turn on sync.

## Decision

ESO.

- Workloads consume a normal Secret, so nothing about the app or its manifests
  is special. Off-the-shelf charts that expect a Secret just work.
- Pods don't need AWS credentials or a network path to AWS. The app pod here
  has no AWS identity and no egress at all.
- A Secrets Manager or STS outage doesn't stop pods from starting - the last
  synced Secret is still there. With the CSI driver, pod start fails if the
  fetch fails.
- One controller makes the AWS calls, so CloudTrail shows one role per
  namespace instead of one call per pod start.

## When the CSI driver is the better choice

- Policy says the value must never be stored in etcd, even encrypted. With ESO
  it always is.
- You want the pod's own identity to be what fetches the secret, so access is
  per workload rather than per namespace.
- You'd rather not run a controller with secret write access and token minting
  rights (see SECURITY.md for what ESO keeps).

## Consequences

The Kubernetes Secret exists, so RBAC on Secrets, pod creation and exec, etcd
encryption, and Gatekeeper rules on how the Secret is consumed all matter. Most
of this POC is about that.
