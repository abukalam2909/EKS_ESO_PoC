# 0005 - Per-namespace identity, no ESO controller role

**Decision:** the ESO controller has no IAM role. Each namespace has a
`secret-reader` SA with its own role (trusting only that SA, reading only that
namespace's secrets). The app runs as a different SA with no AWS access.

**Why:** a controller role would let any ExternalSecret reach any secret, and a
compromised controller would expose all of them. Here STS enforces isolation
even if Kubernetes objects are wrong.

**Limit:** the chart's `scopedNamespace` takes one namespace. More teams means
one ESO per namespace or hand-written RBAC.
