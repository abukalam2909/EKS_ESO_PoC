# 0002 - ESO rather than the Secrets Store CSI Driver

**Decision:** ESO.

**Why:** apps consume a normal Secret, pods need no AWS access, and pods still
start if Secrets Manager is down because the last synced Secret is there.

**Use the CSI driver instead when** policy says the value must never be stored
in etcd, or each workload's own identity should fetch its secret.
