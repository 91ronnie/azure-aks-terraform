# Architecture decision records

Short ADRs: context → decision → consequences. Revisit them before using this for production.

## ADR-001 Single region, single cluster, Free tier

**Context.** Personally operated learning lab; cost is a primary requirement.
**Decision.** One region (default `northeurope`), one AKS cluster, `sku_tier = "Free"`.
**Consequences.** No financially backed API-server SLA; control-plane outages are possible
but rare. Standard tier adds a per-cluster hourly fee (see cost doc). Switching is a
one-line, in-place change (`aks_sku_tier = "Standard"`).

## ADR-002 Public API server restricted by IP, not a private cluster

**Context.** A private cluster needs private DNS, and a path into the VNet for the operator
and the pipeline (VPN gateway, Bastion + jump box, or self-hosted agents).
**Decision.** Public endpoint with `authorized_ip_ranges = operator_ip_ranges`, Entra ID
authentication, Azure RBAC and `local_account_disabled = true`.
**Consequences.** The endpoint is reachable from the Internet but only accepts TCP from the
listed CIDRs and only valid Entra ID tokens. If your home IP changes you must update
`operator_ip_ranges` (from Cloud Shell or the portal). Pipelines never need the API
(GitOps), so Microsoft-hosted agents do not need to be allow-listed.

| | Public + IP allow-list (chosen) | Private cluster |
|---|---|---|
| Attack surface | API reachable from allow-listed IPs | No public API |
| Operator access | Direct `kubectl` | VPN/Bastion/jump box required |
| Pipeline access | Not needed (GitOps) | Not needed (GitOps); Terraform still needs management-plane only |
| Extra cost | none | VPN gateway or Bastion (hourly, see cost doc) + jump box VM |
| Complexity | Low | Private DNS zone, name resolution from clients |

## ADR-003 Azure CNI Overlay with Cilium

**Decision.** `network_plugin = azure`, `network_plugin_mode = overlay`, `network_data_plane = cilium`, `network_policy = cilium`.
**Why.** Pods do not consume VNet IPs; NetworkPolicy is enforced natively; no extra cost.
Kubenet is being retired; flat Azure CNI wastes VNet address space.
**Consequences.** Pod IPs are not directly reachable from the VNet (fine: traffic enters via
the load balancer). Cilium is the supported path forward on AKS.

## ADR-004 One small autoscaling node pool

**Decision.** One `system` pool, `Standard_D2as_v5` (2 vCPU, 8 GiB), autoscaler 1–2,
`only_critical_addons_enabled = false` so FrontRow runs on it too.
**Why.** Smallest non-burstable size with enough memory for AKS add-ons + Argo CD + Traefik
+ cert-manager + the app. Burstable `Standard_B2as_v2` is cheaper and can be selected via
`node_vm_size`, but CPU credits can run out under the always-on add-on load.
**Consequences.** Upgrades surge one extra node temporarily. A failure of the single node
causes a short outage until the replacement is ready.

## ADR-005 GitOps configuration lives in the infrastructure repository

**Context.** Only two repositories are assumed: infrastructure and `web/`.
**Decision.** `gitops/` in this repository holds Argo CD bootstrap, Applications, platform
manifests, the FrontRow chart and per-environment values.
**Why.** One repository for "what runs where" keeps Argo CD's access to one read-only
credential, and the web pipeline needs write access to exactly one repository.
Infrastructure pipeline triggers exclude `gitops/*`, so image bumps never run Terraform.
**Consequences.** The web pipeline's build identity needs `Contribute` on this repository.
If you later want stricter separation (e.g. other people change Terraform), move `gitops/`
into a third repository with the same layout; only `GITOPS_REPO_URL` and the Argo CD
`repoURL`s change.

## ADR-006 Ingress: Traefik, not ingress-nginx or Application Gateway

| Option | Status | Cost | Notes |
|---|---|---|---|
| Kubernetes ingress-nginx | Retired by the Kubernetes project (no further releases) | free | Not acceptable for new builds |
| AKS application routing add-on (managed NGINX) | Supported, NGINX-based; check its support timeline before relying on it | free | Ties ingress lifecycle to the add-on |
| Application Gateway for Containers / AGIC | Supported | fixed hourly + capacity units | Excluded by the cost requirement |
| **Traefik Proxy (chosen)** | Actively maintained (v3.7), supports Ingress + Gateway API | free | One Deployment, Helm chart pinned, upgrades via Argo CD |
| Envoy Gateway | Actively maintained, Gateway API only | free | Good alternative if you want to learn Gateway API first |

**Consequences.** Standard `Ingress` objects with `ingressClassName: traefik`; cert-manager
HTTP-01 works without extra configuration. Migration to Gateway API later is possible with
the same controller.

## ADR-007 TLS: Let's Encrypt at the origin, Cloudflare Full (strict)

**Decision.** cert-manager issues a publicly trusted certificate for `azure-fr.frontrow.co.ke`.
Cloudflare runs in DNS-only mode until the origin works, then proxied with SSL mode Full (strict).
**Why.** A publicly trusted origin certificate works with or without the Cloudflare proxy and
makes troubleshooting straightforward. A Cloudflare Origin CA certificate would be simpler to
renew (up to 15 years) but is only trusted by Cloudflare, so the site breaks if the proxy is
turned off. Both are documented.

## ADR-008 Argo CD installed by script, not by Terraform

**Decision.** Terraform stops at the Azure boundary. Argo CD is installed with a pinned Helm
chart by `gitops/argocd/install-argocd.sh`; everything else in the cluster is reconciled by Argo CD.
**Why.** Avoids the old repository's chicken-and-egg (`cluster_created` flags, providers
configured from data sources of a cluster that may not exist) and keeps Kubernetes objects out
of Terraform state.

## ADR-009 Secrets: Key Vault + CSI driver with workload identity, optional

**Decision.** Provision Key Vault (RBAC mode, purge protection, firewall) and the CSI add-on,
federate a workload identity for the FrontRow service account, but keep the chart's Key Vault
mount disabled.
**Why.** The SPA has no runtime secrets: everything it uses is compiled into public JavaScript.
The plumbing is ready for an exercise or a future server-side component.

## ADR-010 Container Insights with cost controls instead of a self-hosted stack

**Decision.** Azure Monitor agent with a data collection rule (5-minute interval,
ContainerLogV2, `kube-system` excluded), 30-day retention, 0.25 GB/day cap; four platform-metric
alerts; a resource-group budget.
**Why.** Prometheus/Grafana/ELK would need several GiB of RAM on a 8 GiB node.
**Consequences.** When the daily cap is reached, log ingestion stops until 00:00 UTC.

## ADR-011 Remote state in Azure Blob Storage with Entra ID auth

**Decision.** Separate resource group and storage account created by `bootstrap/`, shared keys
disabled, versioning + soft delete, `CanNotDelete` lock, `use_azuread_auth = true`.
**Why.** No storage keys or SAS tokens anywhere; state history is recoverable.
