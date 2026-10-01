# 0003 - IRSA rather than EKS Pod Identity

**Decision:** IRSA.

**Why:** ESO authenticates as the namespace's own SA (`serviceAccountRef`),
which only works with IRSA. ESO's docs say `serviceAccountRef` can't be used
with Pod Identity, so the controller would need its own role - the thing this
design avoids.

**Pod Identity** would give session tags (`kubernetes-namespace`, ...) for ABAC
with one role. To switch: add the pod identity agent and an `eks-auth`
endpoint, trust `pods.eks.amazonaws.com`, create associations. With ESO today
the tags would describe the controller, not the requesting namespace.
