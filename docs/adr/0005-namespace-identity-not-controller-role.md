# 0005 - Per-namespace workload identity, not one ESO controller role

Status: accepted

## Context

The simplest ESO setup gives the controller's SA an IAM role that can read all
the secrets it will ever sync. Then any ExternalSecret in any namespace can
ask for any of those secrets - isolation is left entirely to Kubernetes RBAC on
ExternalSecret objects, and one compromised controller exposes everything.

## Decision

The controller gets no IAM role. Each namespace has:

- `secret-reader` SA, annotated with that namespace's IAM role, running no pods
  (Gatekeeper enforces this)
- a SecretStore authenticating as `secret-reader`
- an IAM role that trusts only `system:serviceaccount:<ns>:secret-reader` and
  can read only that namespace's secrets, with KMS decrypt limited by
  `kms:ViaService` and `kms:EncryptionContext:SecretARN`

The app itself runs as a different SA (`app`) with no annotation, so the app
pod never gets AWS credentials.

The controller is also scoped in Kubernetes: `scopedNamespace` and
`scopedRBAC` so it only has a Role in the app namespace, and token minting is
limited to `secret-reader` by `resourceNames`.

## Consequences

- AWS isolation holds even if Kubernetes objects are misconfigured: a store in
  another namespace can't use this role, because STS checks the `sub`.
- The controller still mints `secret-reader` tokens and reads/writes Secrets in
  its namespace - that's the job and can't be removed (SECURITY.md).
- With more than one namespace, `scopedNamespace` only takes one value. Options
  then are one ESO install per namespace, or turning chart RBAC off and binding
  the controller's Role in each namespace by hand.
