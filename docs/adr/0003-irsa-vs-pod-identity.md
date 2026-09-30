# 0003 - IRSA rather than EKS Pod Identity

Status: accepted

## Context

EKS offers two ways to give a service account an IAM role:

- **IRSA** - the SA is annotated with a role ARN; a projected token is
  exchanged with STS (`AssumeRoleWithWebIdentity`). The role trust policy
  names the cluster's OIDC provider and the exact `sub`
  (`system:serviceaccount:<ns>:<sa>`) and `aud`.
- **EKS Pod Identity** - an association (cluster, namespace, SA -> role) is
  created through the EKS API; an agent on each node hands credentials to the
  pod. The role trusts `pods.eks.amazonaws.com`. Sessions carry tags such as
  `kubernetes-namespace`, `kubernetes-service-account`, `eks-cluster-name`,
  which allow ABAC: one role, policies keyed on
  `aws:PrincipalTag/kubernetes-namespace`.

## Decision

IRSA, because of how ESO works.

The design depends on ESO authenticating as the namespace's own SA
(`auth.jwt.serviceAccountRef`) so the controller never has AWS permissions of
its own. ESO does this by minting a token for that SA and calling
`AssumeRoleWithWebIdentity` - that's IRSA.

ESO's docs are explicit that `serviceAccountRef` can't be used with Pod
Identity: Pod Identity credentials go to the pod that owns the SA, and ESO
can't get them on behalf of another SA. With Pod Identity the controller's own
SA would need a role, so every namespace's secrets would sit behind one
controller identity.

## Switching to Pod Identity later

If ESO gains support for it, or if the controller-role model becomes acceptable:

1. Install the `eks-pod-identity-agent` add-on and add a `com.amazonaws.<region>.eks-auth`
   endpoint (no NAT here).
2. Change the role trust to `pods.eks.amazonaws.com` with `sts:AssumeRole` and
   `sts:TagSession`, and create an `aws_eks_pod_identity_association`.
3. Scope with session tags, e.g. allow `GetSecretValue` on
   `demo/${aws:PrincipalTag/kubernetes-namespace}/*`. That's neat for many
   namespaces, but only works if the tag reflects the namespace that asked,
   not the controller's - with ESO today it would be `external-secrets`.
4. A middle ground ESO supports: give the controller a small role whose only
   permission is to assume per-namespace roles (`spec.provider.aws.role`), and
   use Gatekeeper to pin which role ARN a store in each namespace may name.
   That brings back a controller identity, which is what this POC avoids.

## Consequences

- One OIDC provider per cluster, one trust policy per namespace/SA.
- Tokens for `secret-reader` are the credential; who can mint them matters
  (ESO, only for that SA, and break-glass).
