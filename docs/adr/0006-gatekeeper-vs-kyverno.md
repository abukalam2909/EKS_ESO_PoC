# 0006 - Gatekeeper rather than Kyverno

**Decision:** Gatekeeper, validation only, failing closed. Library templates
for generic pod rules, small custom Rego templates for the ESO rules.
Constraints start in dryrun, then deny.

**Why:** Rego is reusable outside Kubernetes, the library is versioned, and
`gator` tests policies offline. Kyverno would also work and is easier to read
for people who don't know Rego.
