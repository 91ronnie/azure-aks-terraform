# Architecture

FrontRow is a static React single-page application. In the browser it calls external
APIs (REST backend, MQTT broker, Firebase, Auth0, Agora, Stream). Those back-end
services are **outside** this project. The Azure platform therefore only has to:
build, scan and store an image, run a handful of nginx pods, terminate HTTPS and keep
everything reproducible and cheap.

## Context

```mermaid
flowchart TB
  subgraph Cloudflare
    dns[DNS zone frontrow.co.ke<br/>azure-fr A record]
  end
  subgraph AzureDevOps[Azure DevOps]
    repoInfra[(Repo: infra + gitops)]
    repoWeb[(Repo: web)]
    pInfra[Infra pipeline]
    pWeb[Web pipeline]
  end
  subgraph Azure[Azure subscription - single region]
    subgraph rg[rg-frontrow-dev]
      acr[(ACR Basic)]
      kv[(Key Vault)]
      law[(Log Analytics)]
      pipIn[pip-...-ingress]
      pipOut[pip-...-egress]
      subgraph vnet[vnet-frontrow-dev 10.40.0.0/16]
        subgraph snet[snet-aks-nodes 10.40.0.0/22 + NSG]
          node[AKS node pool<br/>1-2 x D2as_v5]
        end
      end
      aks[AKS control plane<br/>Free tier, public API<br/>IP-restricted]
    end
  end
  browser[Browser] --> dns --> pipIn --> node
  node -->|egress| pipOut
  pWeb -->|AcrPush| acr
  pWeb -->|commit tag+digest| repoInfra
  node -->|Argo CD polls| repoInfra
  node -->|AcrPull| acr
  node -->|CSI, service endpoint| kv
  aks --- node
  node -->|Container Insights| law
  pInfra -->|terraform plan/apply| rg
```

## Flows

### 1. Control plane / administration

```mermaid
sequenceDiagram
  participant Op as Operator (az login)
  participant Entra as Microsoft Entra ID
  participant API as AKS API server (public, IP-restricted)
  Op->>Entra: kubelogin (azurecli) token
  Op->>API: kubectl ... (source IP in authorized_ip_ranges)
  API->>Entra: validate token, Azure RBAC check
  API-->>Op: allowed if "AKS RBAC Cluster Admin" (or narrower role)
```

* Local accounts are disabled, so `az aks get-credentials --admin` does not work and no
  static client certificate exists.
* Authorization uses **Azure RBAC for Kubernetes**: roles are assigned in Azure
  (`environments/dev/rbac.tf`), not via `ClusterRoleBinding`s.

### 2. CI / image publishing

```mermaid
sequenceDiagram
  participant Dev as Developer
  participant Repo as Azure Repos (web)
  participant P as Web pipeline (hosted agent)
  participant ACR as ACR
  participant G as GitOps repo (this repo)
  Dev->>Repo: push to main
  Repo->>P: trigger (paths web/*)
  P->>P: npm ci, lint, test, npm audit, Trivy fs, Semgrep
  P->>P: docker build (React production build inside)
  P->>P: Trivy image scan (fail on fixable CRITICAL)
  P->>ACR: push frontrow/web:git-<sha12> (workload identity, AcrPush only)
  P->>G: commit repository/tag/digest to gitops/environments/dev/frontrow/values.yaml ***NO_CI***
```

### 3. GitOps reconciliation

```mermaid
sequenceDiagram
  participant G as GitOps repo
  participant A as Argo CD (in AKS)
  participant K as Kubernetes API
  participant Kubelet as Kubelet (kubelet identity)
  participant ACR as ACR
  A->>G: poll every 3 min (repo credential: workload identity or read-only PAT)
  A->>A: helm template gitops/charts/frontrow + dev values
  A->>K: apply diff (prune + self-heal)
  K->>Kubelet: schedule pod with image repo:tag@sha256
  Kubelet->>ACR: pull (AcrPull)
```

### 4. Application traffic

```mermaid
flowchart LR
  B[Browser] -- HTTPS --> CF{Cloudflare<br/>DNS only at first,<br/>proxied later}
  CF -- HTTPS :443 --> PIP[Static public IP<br/>Standard LB]
  PIP --> NSG[NSG allows 80/443] --> T[Traefik pods<br/>TLS: cert-manager / Let's Encrypt]
  T -- HTTP :8080, NetworkPolicy --> W[FrontRow nginx pods]
  T -. :80 redirects to :443 .-> T
```

### 5. Secret access (optional, Key Vault exercise)

```mermaid
sequenceDiagram
  participant Pod as FrontRow pod (SA frontrow, label azure.workload.identity/use)
  participant CSI as Secrets Store CSI driver (node)
  participant Entra as Entra ID
  participant KV as Key Vault
  CSI->>CSI: request projected SA token (audience api://AzureADTokenExchange)
  CSI->>Entra: exchange token for id-frontrow-dev-frontrow (federated credential)
  CSI->>KV: GET secret (Key Vault Secrets User), via subnet service endpoint
  CSI->>Pod: mount as tmpfs file under /mnt/secrets (rotation every 2 min)
```

FrontRow needs **no** runtime secrets today, so the chart ships with `keyVault.enabled: false`.

## IP plan

| Range | Purpose | Notes |
|---|---|---|
| `10.40.0.0/16` | VNet | Leaves room for future subnets; pick a range that does not overlap any network you may peer/VPN with |
| `10.40.0.0/22` | `snet-aks-nodes` | 1,019 usable IPs = node NICs only (overlay). Even 100 nodes use < 10% |
| `10.40.8.0/24` | reserved: private endpoints | Not created |
| `10.40.12.0/28` | `snet-postgres` (CrateDigger) | Delegated to PostgreSQL Flexible Server; NSG allows 5432 from the node subnet only |
| `10.40.16.0/28` | reserved: API server VNet integration / private cluster | Not created |
| `10.244.0.0/16` | Pod CIDR (overlay) | 256 nodes × /24 each; not routable in the VNet |
| `172.16.0.0/16` | Service CIDR | Cluster-internal virtual IPs |
| `172.16.0.10` | CoreDNS service IP | Must be inside the service CIDR |

Why Azure CNI **Overlay**: pods get IPs from a private overlay range, so the subnet only
needs node addresses and you avoid the classic "subnet ran out of pod IPs" failure.
Why **Cilium** data plane: eBPF-based, enforces Kubernetes `NetworkPolicy` with no extra
component or cost.

## Outbound connectivity

`outbound_type = loadBalancer` with one **Terraform-owned static egress IP**. No NAT
Gateway (hourly + per-GB charge). The node subnet has `default_outbound_access_enabled =
false`, so traffic cannot leave by any implicit path. Key Vault traffic stays on the Azure
backbone through the `Microsoft.KeyVault` service endpoint.

Egress is not filtered by destination (that requires Azure Firewall or an NVA, whose fixed
hourly charge would dominate this lab's bill). Mitigations: FrontRow pods have an egress-deny NetworkPolicy; images are scanned.

## Inbound connectivity and TLS

* `pip-frontrow-dev-ingress` (Standard, static) is attached to the Traefik `LoadBalancer`
  service through the `azure-pip-name` annotation. The address therefore survives cluster
  re-creation and can be put in Cloudflare once.
* NSG rule `allow-ingress-http-https` permits TCP 80/443 from `ingress_allowed_source_prefixes`.
* TLS: Let's Encrypt certificate issued by cert-manager (HTTP-01) and served by Traefik.
  Cloudflare SSL mode **Full (strict)** once proxying is enabled. See
  [cloudflare-dns-tls.md](cloudflare-dns-tls.md).

## Resource inventory

| Resource | Name (dev defaults) | Billing | Purpose |
|---|---|---|---|
| Resource group | `rg-frontrow-dev` | free | Lab resources |
| Node resource group | `rg-frontrow-dev-aks-nodes` | – | Managed by AKS (VMSS, NICs, LB) – never edit by hand |
| VNet / subnet / NSG | `vnet-frontrow-dev`, `snet-aks-nodes`, `nsg-frontrow-dev-aks-nodes` | free | Network |
| Public IP ×2 | `pip-frontrow-dev-ingress`, `pip-frontrow-dev-egress` | hourly | Ingress and egress addresses |
| Standard Load Balancer | `kubernetes` (node RG) | hourly + rules + data | Created by AKS |
| AKS | `aks-frontrow-dev` | control plane free; nodes hourly | Kubernetes |
| VMSS + OS disks | node RG | hourly / monthly | Nodes |
| Managed identities ×4 | `id-frontrow-dev-{aks,kubelet,frontrow,argocd}` | free | Identity |
| ACR | `acrfrontrowdev<suffix>` | daily + storage | Images |
| Key Vault | `kv-frontrow-dev-<suffix>` | per operation | Secrets |
| Log Analytics | `log-frontrow-dev` | per GB ingested beyond free allowance | Logs/insights |
| DCR | `dcr-frontrow-dev-ci` | free | Container Insights settings |
| Alerts / action group / budget | optional | metric alerts ~monthly per rule | Notifications |
| State storage | `rg-frontrow-tfstate` / `stfrontrowtfstate<suffix>` | cents | Terraform state (separate lifecycle) |
| CrateDigger: PostgreSQL, private DNS zone, Key Vault, identity, NSG | `psql-frontrow-dev-<suffix>`, `kv-cd-dev-<suffix>`, `id-frontrow-dev-cratedigger` | hourly (DB) / cents | See docs/cratedigger.md |

## In-cluster components

| Namespace | Component | Installed by | Version |
|---|---|---|---|
| `argocd` | Argo CD | `gitops/argocd/install-argocd.sh` (Helm) | chart 10.11.6 / v3.5.6 |
| `traefik` | Traefik Proxy | Argo CD | chart 42.1.3 / v3.7.16 |
| `cert-manager` | cert-manager | Argo CD | v1.21.3 |
| `frontrow` | FrontRow | Argo CD | image from ACR |
| `kube-system` | CoreDNS, Cilium, CSI drivers, Key Vault provider, metrics-server, AMA (monitoring), workload identity webhook | AKS | managed |

## What changes for production

* Private cluster (or API server VNet integration) + self-hosted agents or a VPN.
* Standard tier (uptime SLA), separate system and user node pools across availability zones,
  at least 2–3 nodes.
* ACR Premium with private endpoint, retention policy, geo-replication if multi-region.
* Key Vault and ACR private endpoints; Azure Firewall/NVA for egress filtering.
* Defender for Containers, Azure Policy with enforced baselines.
* Separate subscriptions per environment, separate state files, PR-based promotion.
* Argo CD SSO with Entra ID, notifications, HA mode.
