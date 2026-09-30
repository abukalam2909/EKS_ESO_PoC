# 0007 - No NAT and a single AZ

Status: accepted

## Context

Private subnets need either NAT or VPC endpoints to reach AWS APIs. NAT also
gives every pod a route to the internet, which is the easiest way to
exfiltrate a secret. Endpoints cost per AZ per hour, and this is a POC.

## Decision

- **No NAT.** The private route table has no default route. AWS APIs are
  reached through interface endpoints (ec2, ecr.api, ecr.dkr, logs, kms, eks,
  ssm, ssmmessages, ec2messages, sts, secretsmanager) and an S3 gateway
  endpoint. Images not in ECR are copied into private ECR repos by digest
  before install. `enable_nat` exists as an off-by-default flag if this gets in
  the way.
- **One AZ.** Nodes, the tunnel host, the rotation Lambda and every endpoint
  are in one AZ. EKS needs control plane subnets in two AZs, so the second AZ
  has one /28 for control plane ENIs and nothing else.
- STS and Secrets Manager endpoints get their own /28, and the control plane
  gets its own /28s, so NetworkPolicies can allow exactly those CIDRs.

## Consequences

- No internet egress means exfiltration needs a way out through AWS itself.
  DNS still resolves public names through the VPC resolver, so DNS tunnelling
  is possible; Route 53 Resolver DNS Firewall would close it and isn't
  included.
- Endpoints in one AZ roughly halve their cost (~88 USD/month instead of ~175).
- An AZ outage takes the whole POC down. Production would use three AZs.
- New third-party images need to be mirrored first, which is also a useful
  supply-chain checkpoint.
