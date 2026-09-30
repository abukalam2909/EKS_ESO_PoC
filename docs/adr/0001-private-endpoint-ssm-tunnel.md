# 0001 - Private API endpoint, reached through an SSM tunnel

Status: accepted

## Context

A public EKS endpoint, even with IAM auth, is an internet-facing control
plane. The private endpoint fixes that but creates a bootstrap problem:
Terraform runs on my laptop, which isn't in the VPC, and something has to
install Gatekeeper, ESO and the app.

Options:

1. Private endpoint only, plus a small host in the VPC reached with SSM
   Session Manager (no SSH, no key pair, no public IP).
   a. run kubectl/helm on that host
   b. use SSM port forwarding through the host and run kubectl/helm on my laptop
2. Public endpoint restricted to my IP, for a limited time.
3. VPN or Direct Connect into the VPC - too much for a POC.

## Decision

1b. Terraform on the laptop manages AWS resources only. Everything in-cluster
is installed through an SSM port forward
(`AWS-StartPortForwardingSessionToRemoteHost`) to the private endpoint.

Why the laptop and not the host:

- kubectl runs as my own IAM role (break-glass / operator / developer), so the
  audit log says which role did what. On a shared host it would be the
  host's instance role or some credential copied onto it.
- The host has no internet, so running tools there means staging kubectl,
  helm and charts into S3 first. More moving parts for no security gain.
- The host role only has `AmazonSSMManagedInstanceCore` and no cluster access.
  Compromising the host gets you a network path, not credentials.

The human roles can only start SSM sessions on instances tagged
`Purpose=eks-tunnel` and only with the port forwarding document.

## Alternative: temporary public endpoint (option 2)

Supported through `public_endpoint_cidrs`, empty by default. If used, treat it
as a security exception:

- justification written down (e.g. SSM unavailable, emergency)
- a /32 or at worst /24, never 0.0.0.0/0 (the variable validation refuses it)
- an expiry - remove it the same day with another apply
- it still needs a valid IAM role with an access entry, so it's
  defence-in-depth loss rather than an open door

I don't recommend it. SSM gives the same result without an internet-facing API.

## Consequences

- Operators need the Session Manager plugin and a local kubeconfig that points
  at `https://localhost:<port>` with `tls-server-name` set to the real endpoint
  hostname (DEPLOY.md).
- SSM session activity is in CloudTrail (`StartSession`).
- If SSM is down, the cluster is unreachable until it's back or the public
  exception is used.
