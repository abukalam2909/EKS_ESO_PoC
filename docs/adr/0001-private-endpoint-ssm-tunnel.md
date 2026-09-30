# 0001 - Private API behind an SSM tunnel, no NAT, one AZ

**Decision:** EKS API is private only. kubectl/helm run on my laptop through an
SSM port forward via a small host (no SSH, no key pair, no public IP, no
cluster permissions). Terraform on the laptop only manages AWS resources.

**Why:** no internet-facing control plane, and kubectl runs as my own role so
the audit log shows who did what.

**Alternative:** `public_endpoint_cidrs` opens the API to a /32 as a temporary,
written-down exception with a same-day expiry. Not recommended.

**Also:** no NAT (AWS reached through VPC endpoints, images mirrored to ECR),
and everything in one AZ to keep cost down. Downside: no AZ redundancy, and DNS
tunnelling is still possible without DNS Firewall.
