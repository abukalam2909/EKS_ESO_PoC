# Deploy

Everything is manual. Terraform manages AWS; everything in the cluster goes
through an SSM tunnel from the laptop.

Tools: Terraform >= 1.11, AWS CLI v2 + Session Manager plugin, kubectl, Helm 3,
jq, [crane](https://github.com/google/go-containerregistry/tree/main/cmd/crane).

## 1. Check the account

```sh
aws sts get-caller-identity          # right account? right role?
```

Fill in `terraform/terraform.tfvars` from `terraform.tfvars.example`.
`admin_principal_arn` must be the IAM role behind your session (for SSO:
`aws iam get-role --role-name <role name> --query Role.Arn`). Terraform refuses
to run as anyone else.

## 2. Terraform

```sh
cd terraform
terraform init
terraform plan -out tfplan
```

Look at the plan before applying:

- no `aws_secretsmanager_secret_version` anywhere
- `endpoint_public_access = false`, no route to `0.0.0.0/0`, no NAT (unless you set `enable_nat`)
- KMS key policies: admin has no Encrypt/Decrypt
- the account ID and region are the ones you expect

```sh
terraform apply tfplan
```

Takes ~20 min. Confirm the SNS subscription email. The rotation Lambda runs
once at the end and creates the first secret value:

```sh
aws secretsmanager describe-secret --secret-id demo/app/api-key --query VersionIdsToStages
```

Handy variables for the rest:

```sh
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export REG=$(terraform output -raw ecr_registry)
export EP=$(terraform output -raw cluster_endpoint | sed 's#https://##')
export HOST=$(terraform output -raw tunnel_host_id)
cd ..
```

## 3. Mirror images

The cluster has no internet. Copy the three images by digest (crane keeps the
digest identical):

```sh
aws ecr get-login-password | crane auth login "$REG" -u AWS --password-stdin
crane copy ghcr.io/external-secrets/external-secrets@sha256:66fb710878cbf3eba4a927e35c5d75e29a202c9bab238aad64bfb23b786b962b "$REG/mirror/external-secrets:v2.11.0"
crane copy docker.io/openpolicyagent/gatekeeper@sha256:dfc6fc78753f5564303429c1c1fdfe611df17be224ab22c09ce9d2a73c468a8d "$REG/mirror/gatekeeper:v3.23.1"
crane copy docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e "$REG/mirror/busybox:1.37.0"
```

## 4. Tunnel and kubeconfig

Add a profile per human role to `~/.aws/config` (role ARNs from
`terraform output human_role_arns`):

```ini
[profile demo-break-glass]
role_arn = arn:aws:iam::<account>:role/demo-break-glass
source_profile = default
```

Same for `demo-operator` and `demo-developer`.

Open the tunnel in its own terminal and leave it running:

```sh
aws ssm start-session --target "$HOST" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$EP,portNumber=443,localPortNumber=8443"
```

Point kubectl at it:

```sh
aws eks update-kubeconfig --name demo-eks --profile demo-break-glass --alias demo
CLUSTER_ARN=$(kubectl config view -o jsonpath='{.contexts[?(@.name=="demo")].context.cluster}')
kubectl config set-cluster "$CLUSTER_ARN" --server=https://localhost:8443 --tls-server-name="$EP"
kubectl get nodes
```

Break-glass is used for the install. Its actions show in the audit log as
`break-glass:<session>`.

## 5. Install

`ACCOUNT_ID` in the manifests is replaced on the way in.

```sh
sub() { sed "s/ACCOUNT_ID/$ACCOUNT/g" "$@"; }

# Gatekeeper first, so everything after it is checked
kubectl label ns kube-system admission.gatekeeper.sh/ignore=no-self-managing
kubectl apply -f kubernetes/gatekeeper/namespace.yaml
sub kubernetes/gatekeeper/values.yaml | helm install gatekeeper gatekeeper \
  --repo https://open-policy-agent.github.io/gatekeeper/charts --version 3.23.1 \
  -n gatekeeper-system -f -
kubectl -n gatekeeper-system rollout status deploy --timeout=180s   # webhook fails closed, wait for it
kubectl apply -f kubernetes/gatekeeper/templates/library -f kubernetes/gatekeeper/templates/custom
sleep 30   # let the constraint CRDs register
sub kubernetes/gatekeeper/constraints/*.yaml | kubectl apply -f -

# namespaces and RBAC
kubectl apply -f kubernetes/namespaces.yaml -f kubernetes/rbac.yaml

# ESO, then its extra RBAC and network policy
sub kubernetes/eso/values.yaml | helm install external-secrets external-secrets \
  --repo https://charts.external-secrets.io --version 2.11.0 \
  -n external-secrets -f -
kubectl apply -f kubernetes/eso/rbac.yaml -f kubernetes/eso/networkpolicy.yaml
kubectl -n external-secrets rollout status deploy --timeout=180s

# the app
sub kubernetes/app/serviceaccounts.yaml | kubectl apply -f -
kubectl apply -f kubernetes/app/secretstore.yaml -f kubernetes/app/externalsecret.yaml -f kubernetes/app/networkpolicy.yaml
sub kubernetes/app/deployment.yaml | kubectl apply -f -

kubectl get secretstore,externalsecret -n demo-app      # both Ready
kubectl logs deploy/demo-app -n demo-app --tail=1        # "api-key sha256=<12 chars>"
```

## 6. Gatekeeper: dryrun, then deny

Constraints start as dryrun. Give the audit a couple of minutes, then:

```sh
kubectl get constraints -o custom-columns=NAME:.metadata.name,MODE:.spec.enforcementAction,VIOLATIONS:.status.totalViolations
```

Anything with violations: look at `kubectl get <kind> <name> -o yaml` under
`status.violations` and fix it. When clean, switch to deny:

```sh
for c in $(kubectl get constraints -o name); do
  kubectl patch "$c" --type merge -p '{"spec":{"enforcementAction":"deny"}}'
done
```

If Gatekeeper itself breaks and blocks everything (it fails closed), remove the
webhook as break-glass and reinstall:
`kubectl delete validatingwebhookconfiguration gatekeeper-validating-webhook-configuration`.

## 7. Verify

Each check should give the result shown. Nothing here prints a secret value.

**V-01 IRSA trust** - a token for the wrong SA can't assume the app role:
```sh
APP_ROLE=$(terraform -chdir=terraform output -raw app_secret_reader_role_arn)
kubectl create token app -n demo-app --audience sts.amazonaws.com > /tmp/t && chmod 600 /tmp/t
aws sts assume-role-with-web-identity --role-arn "$APP_ROLE" --role-session-name v01 \
  --web-identity-token file:///tmp/t --query AssumedRoleUser.Arn    # AccessDenied
rm /tmp/t
```

**V-02 IMDS** - no node credentials from a pod:
```sh
kubectl exec -n demo-app deploy/demo-app -- wget -T 3 -O- http://169.254.169.254/latest/meta-data/   # fails
```

**V-03 developer** - all `no` except the last:
```sh
for c in "get secrets" "list secrets" "create pods" "create deployments" \
         "create pods --subresource=exec" "create externalsecrets.external-secrets.io" \
         "create rolebindings" "get pods"; do
  echo "$c: $(kubectl auth can-i $c -n demo-app --as developer:v --as-group developers)"
done
```

**V-04 operator** - can manage ExternalSecrets, can't read Secrets:
```sh
kubectl auth can-i create externalsecrets.external-secrets.io -n demo-app --as operator:v --as-group platform-operators   # yes
kubectl auth can-i get secrets -n demo-app --as operator:v --as-group platform-operators                                 # no
```

**V-05 admission** - after switching to deny, all rejected:
```sh
kubectl run bad --image=busybox -n demo-app --dry-run=server                                  # not from ECR, no digest, PSA
kubectl create secret generic manual --from-literal=k=x -n demo-app --dry-run=server         # only ESO may write Secrets
kubectl api-resources | grep -iE 'clustersecretstore|pushsecret'                              # nothing
kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata: { name: static, namespace: demo-app }
spec:
  provider:
    aws:
      service: SecretsManager
      region: ca-central-1
      auth: { secretRef: { accessKeyIDSecretRef: { name: k, key: id }, secretAccessKeySecretRef: { name: k, key: s } } }
EOF
# static credentials -> denied
kubectl get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration \
  -o jsonpath='{.webhooks[*].failurePolicy}'    # Fail Fail
```

**V-06 network** - the app pod can't reach anything:
```sh
kubectl exec -n demo-app deploy/demo-app -- nc -w 3 1.1.1.1 443          # fails
kubectl exec -n demo-app deploy/demo-app -- nc -w 3 172.20.0.10 53       # fails (no DNS)
```

**V-07 ESO scope**:
```sh
kubectl get sa external-secrets -n external-secrets -o jsonpath='{.metadata.annotations}'         # no role-arn
kubectl auth can-i list secrets -A --as system:serviceaccount:external-secrets:external-secrets   # no
kubectl auth can-i create serviceaccounts/app --subresource=token -n demo-app \
  --as system:serviceaccount:external-secrets:external-secrets                                   # no
```

**V-08 outside the VPC + alert** - from the laptop. The app role is allowed by
IAM, so its denial here comes from the VPC endpoint rule:
```sh
kubectl create token secret-reader -n demo-app --audience sts.amazonaws.com > /tmp/t && chmod 600 /tmp/t
read -r AK SK ST <<<"$(aws sts assume-role-with-web-identity --role-arn "$APP_ROLE" --role-session-name v08 \
  --web-identity-token file:///tmp/t --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)"
rm /tmp/t
AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST \
  aws secretsmanager get-secret-value --secret-id demo/app/api-key --query VersionId   # AccessDenied
unset AK SK ST
```
Then as break-glass, which isn't on the alert allowlist:
```sh
aws secretsmanager get-secret-value --secret-id demo/app/api-key --query VersionId --profile demo-break-glass   # AccessDenied
```
The alert email should arrive within a few minutes.

**V-09 rotation reaches the pod**:
```sh
kubectl logs deploy/demo-app -n demo-app --tail=1                          # note the hash
aws secretsmanager rotate-secret --secret-id demo/app/api-key
sleep 30
kubectl annotate externalsecret app-api-key -n demo-app force-sync=$(date +%s) --overwrite
kubectl logs deploy/demo-app -n demo-app -f                                # new hash within ~2 min, same pod
```

**V-10 posture**:
```sh
aws eks describe-cluster --name demo-eks --query 'cluster.{public:resourcesVpcConfig.endpointPublicAccess,kms:encryptionConfig[0].provider.keyArn,auth:accessConfig.authenticationMode}'
terraform -chdir=terraform state list | grep secret_version       # nothing
```

Optional: `kubescape scan framework nsa` through the tunnel for a quick
posture report.

## 8. Teardown

```sh
terraform -chdir=terraform destroy
```

Deleting the cluster removes everything inside it. Lambda network interfaces
can take 20+ minutes to release, which holds up the subnet and security group
deletes - just let it finish or re-run.

The secret and KMS keys go into a 7-day pending deletion. To reuse the secret
name straight away:

```sh
aws secretsmanager delete-secret --secret-id demo/app/api-key --force-delete-without-recovery
```

Check for leftovers (KMS keys pending deletion are expected):

```sh
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=eks-secrets-demo \
  --query 'ResourceTagMappingList[].ResourceARN'
```

Remove the `demo-*` profiles from `~/.aws/config` and the `demo` kubeconfig
context.

## 9. Next day

Check billing once the day's usage is in:

```sh
aws ce get-cost-and-usage --time-period Start=$(date -v-2d +%F),End=$(date +%F) \
  --granularity DAILY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
```

EKS, EC2, VPC (endpoints) and KMS should stop accruing after the destroy day.
