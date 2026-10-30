# Security

Controls are marked **Enforced** (technically prevents the bad outcome), **Gate** (a
pipeline fails), **Advisory** (reported, not blocking) or **Paid/optional** (needs an extra
product or licence).

## Identity and access

### Three different authorization systems

| Layer | Question it answers | Configured in |
|---|---|---|
| **Azure RBAC** (management + data plane) | May this principal create a VM, push to ACR, read a Key Vault secret? | `environments/dev/rbac.tf` |
| **Kubernetes RBAC** (via Azure RBAC for Kubernetes) | May this user `get pods` in namespace X? | Azure role assignments on the AKS resource (`Azure Kubernetes Service RBAC *` roles) |
| **Application authorization** | May this FrontRow user see patient Y? | The external backend API / Auth0 – outside this platform |

### Principals and their permissions

| Principal | Type | Roles | Scope | Why |
|---|---|---|---|---|
| You (operator) | User | Azure Kubernetes Service RBAC Cluster Admin | AKS | Day-2 operations, Argo CD bootstrap |
| You (operator) | User | Key Vault Secrets Officer | Key Vault | Create/rotate secrets (data plane) |
| You (operator) | User | Contributor + RBAC Administrator (constrained) | RG / subscription | Run Terraform locally |
| Terraform pipeline (`sc-frontrow-infra-dev`) | SP/MI via workload identity federation | Plan: Reader + Storage Blob Data Contributor (state). Apply: Contributor + constrained RBAC Administrator | RG + state account | Infrastructure changes, only after approval |
| Web pipeline (`sc-frontrow-acr-push`) | SP/MI via workload identity federation | **AcrPush** | ACR | Publish images. No AKS, no Key Vault, no RG rights |
| Web pipeline build identity | Azure DevOps identity | Contribute | Infra (GitOps) repository | Commit image tag/digest |
| AKS control plane `id-frontrow-dev-aks` | User-assigned MI | Managed Identity Operator (kubelet MI), Network Contributor (subnet, both public IPs) | Those resources | Assign kubelet identity, manage LB/IP/NICs |
| Kubelet `id-frontrow-dev-kubelet` | User-assigned MI | **AcrPull** | ACR | Pull images |
| FrontRow workload `id-frontrow-dev-frontrow` | User-assigned MI + federated credential `system:serviceaccount:frontrow:frontrow` | Key Vault Secrets User | Key Vault | Read secrets if the chart enables Key Vault |
| CrateDigger workload `id-frontrow-dev-cratedigger` | User-assigned MI + federated credential `system:serviceaccount:cratedigger:cratedigger` | Key Vault Secrets User (own vault); **PostgreSQL Entra administrator** (server-level, not Azure RBAC) | CrateDigger vault / server | Read app secrets; create and own its database (docs/cratedigger.md) |
| Argo CD `id-frontrow-dev-argocd` | User-assigned MI + federated credentials for `argocd-repo-server`, `-application-controller`, `-server` | **none in Azure** | – | Optional Azure Repos read access (granted inside Azure DevOps) |
| Argo CD (in-cluster) | Kubernetes SA | cluster-admin-equivalent ClusterRole (chart default) | Cluster | It must create everything it deploys; limited by AppProjects (`gitops/argocd/projects.yaml`) |

Nothing has Owner. No principal has a client secret or certificate. Static AKS admin
credentials do not exist (`local_account_disabled = true`).

### Bootstrap vs steady state

1. **Bootstrap** (you, locally): Contributor + RBAC Administrator at subscription scope, because
   the resource group does not exist yet.
2. **After the first apply**: re-scope your and the pipeline's RBAC Administrator assignment to
   `rg-frontrow-dev` with the "only these roles" condition (prerequisites.md). Remove
   subscription-scope assignments.
3. **Plan-only identity** (optional): create a second service connection with Reader for
   PR validation so unapproved branches can never hold write permissions.

### Workload identity federation for Azure DevOps

The service connection creates (or you supply) an Entra ID app registration / managed identity
with a **federated credential** whose subject is
`sc://<org>/<project>/<service-connection-name>`. At run time Azure DevOps issues a short-lived
OIDC token; Entra ID exchanges it for an Azure access token. In the pipelines this is
`addSpnToEnvironment: true` → `ARM_OIDC_TOKEN=$idToken`, `ARM_USE_OIDC=true`.

## Secrets

### Configuration classification (FrontRow)

| Class | Examples | Where it lives |
|---|---|---|
| 1. Public build-time | `REACT_APP_ENDPOINT`, `REACT_APP_SERVER_ENDPOINT`, `REACT_APP_MQTT_HOST/PORT`, `REACT_APP_AUTH0DOMAIN/CLIENT_ID/AUDIENCE`, `REACT_APP_FIREBASE_*` (Firebase web config is public by design), `REACT_APP_CURRENT_ENV` | Azure DevOps variable group `frontrow-web-dev` (not secret) → Docker build args → compiled JS |
| 2. Non-sensitive runtime | ingress host, replica counts, issuer name | Helm values in `gitops/environments/dev/` |
| 3. Sensitive runtime | **none today** | Would go to Key Vault, mounted via CSI (chart `keyVault.*`) |

Anything a browser downloads is public. The old CodeBuild template passed
`REACT_APP_KORE_CLIENT_SECRET` and `REACT_APP_ALGOLIA_APP_SECRET` into the build – such values
are visible to every user. If they are real secrets they must move behind a server-side
endpoint (e.g. the backend issues short-lived tokens), not into Key Vault for the SPA.

### Rules

* **Enforced**: no secrets in Terraform variables/outputs (none defined), Key Vault RBAC only,
  purge protection, firewall default-deny, storage account shared keys disabled.
* **Gate**: Trivy secret scanning in both pipelines; Checkov secrets framework (infra).
* Secret values are written out-of-band: `az keyvault secret set --vault-name … --name … --file …`
  (prefer `--file` over `--value` so the value is not kept in shell history).
* Pipeline variables: none of the variables in this design are secret. If you ever add one,
  mark it secret, map it explicitly through `env:` and never `echo` it.

### Key Vault vs mounted secrets vs Kubernetes Secrets

| | Key Vault | CSI-mounted file | Kubernetes Secret |
|---|---|---|---|
| Source of truth | ✔ | copy | copy |
| At rest | HSM-backed service encryption | tmpfs in the pod (memory) | etcd (encrypted at rest by AKS) |
| Who can read | Azure RBAC on the vault | processes in that pod | anyone with `get secrets` in the namespace |
| Rotation | new version in the vault | CSI driver polls every 2 min (`secret_rotation_interval`) and updates the file | only if `secretObjects` sync is used, and then pods need a restart for env vars |

The chart deliberately does **not** sync to a Kubernetes Secret. An application that reads the
file on each use picks up rotations automatically; one that reads it at start-up needs a rollout
restart (`kubectl rollout restart deploy/frontrow -n frontrow`).

### Rotation procedure (exercise)

```bash
KV=$(terraform -chdir=environments/dev output -raw key_vault_name)
printf 'v2-%s' "$(openssl rand -hex 8)" > /tmp/s && az keyvault secret set --vault-name "$KV" -n frontrow-demo-secret --file /tmp/s && rm /tmp/s
kubectl -n frontrow exec deploy/frontrow -- cat /mnt/secrets/frontrow-demo-secret   # changes within ~2 min
```

Your workstation IP must be in `operator_ip_ranges` for the data-plane call to pass the firewall.

### Terraform state

State contains resource IDs, identity client IDs and the AKS cluster's (non-admin) kubeconfig
template – no passwords by design, but treat it as sensitive: it lives in a private container,
Entra-ID-only access, versioning + soft delete, delete lock.

## Network

| Control | Status |
|---|---|
| Node subnet NSG: inbound only 80/443 (+ Azure LB probes, VNet) | Enforced |
| API server allow-list (`authorized_ip_ranges`) | Enforced |
| No default outbound access; single static egress IP | Enforced |
| Key Vault firewall: operator IPs + node subnet only | Enforced |
| FrontRow NetworkPolicy: ingress only from `traefik` namespace, no egress | Enforced (Cilium) |
| HTTPS redirect (Traefik `web` → `websecure`) and HSTS header | Enforced |
| Restrict 80/443 to Cloudflare IP ranges | Optional, after proxy is enabled (`ingress_allowed_source_prefixes`) |
| Destination-based egress filtering | Not implemented (needs Azure Firewall – paid) |
| ACR / Key Vault private endpoints | Not implemented (ACR Basic doesn't support it; cost) |

NSGs filter at the NIC/subnet level and cannot distinguish pods; pod-level isolation is the job
of NetworkPolicy.

## Kubernetes hardening

| Control | Status |
|---|---|
| Pod Security Admission `restricted` on `frontrow`, `traefik`, `cert-manager` namespaces | Enforced |
| `baseline` (enforce) + `restricted` (warn) on `argocd` | Enforced |
| Non-root (uid 101), read-only root FS, all capabilities dropped, no privilege escalation, `RuntimeDefault` seccomp | Enforced by the chart and PSA |
| `automountServiceAccountToken: false` for FrontRow | Enforced |
| Resource requests on every container; memory limits | Enforced by the chart (no CPU limit on purpose: avoids throttling, see accepted risks) |
| Image referenced by digest | Enforced when the pipeline sets `image.digest` |
| `latest` tag rejected | Enforced (chart `fail`) |
| Azure Policy add-on (Gatekeeper) | Optional (`azure_policy_enabled`), free, costs node memory |
| Defender for Containers (runtime threat detection, registry scanning) | Paid/optional |
| AKS image cleaner (removes unused images from nodes every 48 h) | Enforced |
| Automatic patch upgrades + weekly node OS image upgrades in a maintenance window | Enforced |

## Vulnerability management

| Scan | Tool | Where | Threshold |
|---|---|---|---|
| Dependency (prod deps) | `npm audit --omit=dev` | web pipeline | Gate: CRITICAL |
| Dependency + lockfile | Trivy fs | web pipeline | Gate: fixable CRITICAL; HIGH reported |
| Secrets | Trivy (secret scanner) | both pipelines | Gate: any |
| SAST | Semgrep (`p/javascript`, `p/react`, `p/secrets`) | web pipeline | Advisory until baseline triaged |
| Container image (OS + app) | Trivy image | web pipeline | Gate: fixable CRITICAL |
| Dockerfile | Trivy config | web pipeline | Gate: HIGH/CRITICAL |
| Terraform | Checkov + Trivy config | infra pipeline | Gate: any failed Checkov check not in `.checkov.yaml`; Trivy HIGH/CRITICAL |
| Kubernetes manifests (rendered chart) | Trivy config | web pipeline GitOps stage | Gate: HIGH/CRITICAL |
| Base images | `node:24.x-alpine` (LTS), `nginx-unprivileged:1.30.x-alpine` (stable branch) | Dockerfile | Bump monthly or on CVE |

Traceability: image tag `git-<sha12>`, OCI labels (`revision`, `version`, `source`),
`/build-info.json` in the image, GitOps commit message containing build number and full SHA.

### Handling a finding

1. Read the advisory: is the vulnerable code shipped (runtime image / browser bundle) or only
   in build tooling? `npm ls <pkg>` shows the path.
2. Prefer upgrading the direct dependency, then an `overrides` entry in `package.json`, then a
   base-image bump.
3. Accept only with a written reason: add the ID to `web/.trivyignore` (or
   `.trivyignore.yaml` / `.checkov.yaml` here) with **reason, owner, review date**.
4. Never lower a threshold globally to make one finding pass.

## Accepted risks

| ID | Risk | Mitigation | Revisit |
|---|---|---|---|
| AZU-0047 / NSG | 80/443 open to the Internet | Only ingress listens; narrow to Cloudflare ranges | after proxy enabled |
| AZU-0065, CKV_AZURE_115 | Public API endpoint | IP allow-list, Entra ID, local accounts disabled | before production |
| CKV_AZURE_139/164/165/166/167/233/237 | ACR Basic lacks Premium features | Digest pinning, Trivy gate, optional purge task | if moving to Premium |
| CKV_AZURE_163 | No Defender registry scanning | Trivy in CI | – |
| CKV_AZURE_117 | Platform-managed disk keys | Encryption at host enabled | production |
| CKV_AZURE_232 | Apps share the system pool | Small lab; resource requests set | production |
| CKV2_AZURE_32 | Key Vault public endpoint | Firewall default-deny + service endpoint | production |
| KSV-0011 | No CPU limit on FrontRow | Requests set; nginx is light; avoids CFS throttling | – |
| CKV_AZURE_136 | PostgreSQL without geo-redundant backup | 7-day local PITR backups | production |
| CKV2_AZURE_57 | "No private endpoint" on PostgreSQL | VNet integration: no public endpoint exists at all | – |
| AZU-0021 | PostgreSQL connection throttling not configured | NSG (AKS nodes only) + Entra-only auth | 2027-01-31 |
| KSV-0020/0021 | UID/GID 101 (< 10000) | Fixed by the upstream nginx-unprivileged image; non-root enforced | – |

## Content-Security-Policy

Not set yet. `public/index.html` loads scripts from unpkg, webrtc.github.io (`adapter-latest.js`,
unpinned), Google Tag Manager, Zendesk and others. Rollout plan:

1. Add `Content-Security-Policy-Report-Only` in `web/nginx/default.conf` listing the observed origins.
2. Watch the browser console / a report endpoint for a week.
3. Switch to enforcing; pin or self-host `adapter-latest.js` and `supercluster` (supply-chain risk).
