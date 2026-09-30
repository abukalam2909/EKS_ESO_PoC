# 0006 - OPA Gatekeeper rather than Kyverno

Status: accepted

## Context

Several rules here can't be expressed with Pod Security Admission or RBAC:
ESO-specific fields (static credentials, cross-namespace SA refs, provider type),
"only ESO may write Secrets in this namespace", no secrets in env vars, no
subPath on secret volumes. Both Gatekeeper and Kyverno can do all of them.

## Decision

Gatekeeper.

- Rego is used outside Kubernetes too (OPA, Conftest, AWS policy tooling), so
  it's a skill a security team is more likely to already have and review.
- The gatekeeper-library covers the generic pod rules with maintained,
  versioned templates; I vendored and pinned those and only wrote Rego for the
  ESO and secret-handling rules.
- `gator` tests policies offline against sample objects, including
  AdmissionReviews for the rule that depends on the requesting user.
- Validation only - mutation is off, so policies never change what was applied.

Kyverno would have been fine. Its YAML policies are easier to read for people
who don't know Rego, and it can generate and mutate resources, which isn't
wanted here.

## Consequences

- Constraints ship as `dryrun`, then move to `deny` once the audit is clean.
- The webhook fails closed (`failurePolicy: Fail`), with `kube-system` and
  `gatekeeper-system` exempt so a broken Gatekeeper doesn't stop the cluster
  from recovering.
- Rules on Pods are checked at the Pod, so a bad Deployment is accepted and its
  pods are rejected; the reason shows in the ReplicaSet events.
