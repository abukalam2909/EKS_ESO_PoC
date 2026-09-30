# 0004 - Namespaced SecretStore only, no ClusterSecretStore

Status: accepted

## Context

A `ClusterSecretStore` can be referenced from any namespace. Whatever identity
it uses, every namespace that can create an ExternalSecret can read every
secret that identity can read. `ClusterExternalSecret` goes the other way and
writes Secrets into many namespaces. `PushSecret` copies in-cluster Secrets out
to a store, which is an exfiltration path.

## Decision

Only namespaced `SecretStore` and `ExternalSecret`.

- The cluster-scoped and push CRDs aren't installed
  (`crds.createClusterSecretStore: false` etc.) and the controller doesn't
  process them. The kinds don't exist in the API.
- Gatekeeper still denies them in case a chart upgrade brings the CRDs back,
  and also denies ESO generators, which the chart installs regardless.
- ExternalSecrets may only reference a `SecretStore`, never a
  `ClusterSecretStore` or a generator.
- A store's `serviceAccountRef` must be in its own namespace.

## Consequences

Each namespace needs its own store and its own IAM role. That's more objects
but it keeps the blast radius of any one namespace to its own secrets, and
it's easy to template per team.
