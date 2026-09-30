# 0004 - Namespaced SecretStore only

**Decision:** no ClusterSecretStore, ClusterExternalSecret or PushSecret. Their
CRDs aren't installed and Gatekeeper denies them anyway.

**Why:** a cluster store lets every namespace read whatever its identity can
read; PushSecret can copy Secrets out of the cluster. Namespaced stores keep
each namespace to its own secrets, at the cost of one store and one role per
namespace.
