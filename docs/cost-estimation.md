# Cost estimation

**Source.** Unit prices below were retrieved from the public
[Azure Retail Prices API](https://prices.azure.com/api/retail/prices) on **2026-10-29**,
pay-as-you-go, USD, Linux, `northeurope` unless stated. Prices change; taxes, discounts,
credits, reservations and currency conversion are excluded. Re-check in the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) and watch
*Cost Management → Cost analysis* filtered by tag `project = frontrow`.

A month is taken as 730 hours.

## Unit prices used

| Item | Meter (API) | Unit price |
|---|---|---|
| Node VM `Standard_D2as_v5` (2 vCPU, 8 GiB) | Dasv5 Series, D2as v5 | $0.096 / h |
| Alternative `Standard_B2as_v2` (burstable, 2 vCPU, 8 GiB) | Basv2 Series, B2as v2 | $0.0816 / h |
| Alternative `Standard_B2als_v2` (burstable, 2 vCPU, 4 GiB) | Basv2 Series | $0.0408 / h (too little RAM for this add-on set) |
| OS disk 64 GiB Premium SSD (P6) | Premium SSD Managed Disks, P6 LRS | $10.207 / month |
| OS disk 32 GiB Premium SSD (P4) | P4 LRS | $5.28 / month |
| Standard static public IPv4 | IP Addresses, Standard IPv4 Static | $0.005 / h |
| AKS control plane, Free tier | – | $0 |
| AKS Standard tier (uptime SLA) | Azure Kubernetes Service, Standard Uptime SLA | $0.10 / h |
| ACR Basic | Container Registry, Basic Registry Unit | $0.1666 / day (10 GiB included) |
| Log Analytics ingestion (Analytics logs) | Analytics Logs Data Ingestion | $2.76 / GB after the free tier |
| Key Vault Standard operations | Key Vault, Operations | $0.03 / 10,000 |
| Internet egress | Standard Data Transfer Out | first 100 GB/month $0, then $0.08 / GB |
| Standard Load Balancer | *not returned by the API query used* | verify in the calculator (historically billed per rule-hour for the first 5 rules plus per GB processed) |

## Baseline monthly estimate (dev, 1 node always on)

| Item | Calculation | USD / month |
|---|---|---|
| 1 × D2as_v5 node | 0.096 × 730 | 70.08 |
| OS disk P6 | | 10.21 |
| 2 × static public IP (ingress, egress) | 2 × 0.005 × 730 | 7.30 |
| Standard Load Balancer (AKS creates it; 3 rules: outbound + 80 + 443) | **unverified**, see note | ~18 (assumption) |
| ACR Basic | 0.1666 × 30.4 | 5.07 |
| Log Analytics | 1–3 GB/month typical with the DCR settings; up to 7.6 GB at the 0.25 GB/day cap | 0 – 21 |
| Key Vault | < 10k operations | < 0.10 |
| Egress | < 100 GB | 0 |
| Terraform state storage (LRS, a few MB + versions) | | < 0.50 |
| Metric alerts (4) / budget | metric alert rules are billed per monitored time series (not queried) | small / 0 |
| Cloudflare (Free plan) | | 0 |
| **Total (typical)** | | **≈ 110 – 135** |
| + CrateDigger: PostgreSQL B1ms ($0.018/h) + 32 GiB storage (price not retrieved) + private DNS zone | 0.018 × 730 + storage | ≈ 13 + storage (`cratedigger_enabled = false` removes it) |

Load balancer note: the ~$18 figure assumes the long-standing rate of about $0.025 per hour
for the first five rules. It could not be confirmed from the API on the pricing date – check it.

### Variations

| Change | Effect |
|---|---|
| Autoscaler adds the 2nd node | + ~$80 (VM + disk) while it runs |
| `node_vm_size = "Standard_B2as_v2"` | − ~$11 per node; risk of CPU-credit exhaustion |
| `node_os_disk_size_gb = 32` | − ~$5 per node (less image cache space) |
| `aks_sku_tier = "Standard"` | + $73 |
| `container_insights_enabled = false` | − Log Analytics ingestion (loses logs/insights) |
| Upgrade surge | + 1 node for ~10–30 minutes per upgrade |

### Regional comparison (D2as_v5, per node-month, 730 h)

| Region | $/h | $/month | Comment |
|---|---|---|---|
| eastus2 | 0.086 | 62.78 | Cheapest of those checked; ~200+ ms from Nairobi |
| **northeurope** (default) | 0.096 | 70.08 | Good price/latency balance from East Africa |
| westeurope | 0.104 | 75.92 | |
| southafricanorth | 0.115 | 83.95 | Lowest latency from Kenya; ~20% more expensive |

## Public endpoint lab vs private cluster

| Extra for a private cluster | Unit price (API, northeurope) | Monthly |
|---|---|---|
| Point-to-site VPN gateway VpnGw1 | $0.19 / h + $0.01 / h per P2S connection | ≈ 139 + 7 |
| *or* Azure Bastion Basic | $0.19 / h | ≈ 139 |
| *or* VPN gateway Basic (legacy SKU, limited features) | $0.036 / h | ≈ 26 |
| Jump box / self-hosted agent VM (e.g. B2als_v2) | $0.0408 / h | ≈ 30 |
| Private DNS zone, private endpoints (Key Vault, ACR Premium) | not queried; ACR Premium alone is $1.6666/day ≈ $51 | 50+ |

So a private design roughly **doubles** the lab cost. Security benefit: no public API
endpoint at all. The chosen design compensates with IP allow-listing + Entra ID + disabled
local accounts (ADR-002).

## What keeps costing money

| Resource | Stops charging when… |
|---|---|
| Node VMs | autoscaler scales down / `az aks stop` / destroy |
| OS disks | nodes are deleted (stop or destroy) |
| Public IPs (static) | **only when deleted** – they bill even when the cluster is stopped |
| Standard Load Balancer | the cluster is stopped or destroyed (verify in Cost analysis) |
| ACR Basic | **only when deleted** (daily unit) |
| Log Analytics | ingestion stops when the cluster is stopped; retained data within 30 days is free |
| Key Vault | per operation only; a soft-deleted vault does not bill |
| PostgreSQL Flexible Server | compute stops while the server is stopped (max 7 days, then Azure restarts it); storage and backups bill until deleted |
| State storage | negligible, keep it |

## Saving money day to day

```bash
# Stop the whole cluster (control plane + nodes). Static IPs, ACR, LB config remain.
az aks stop  -g rg-frontrow-dev -n aks-frontrow-dev
az aks start -g rg-frontrow-dev -n aks-frontrow-dev     # ~5-10 min; Argo CD resumes reconciling

# Keep the cluster but cap it at one node
terraform apply -var node_max_count=1
```

Do not run `terraform apply` while the cluster is stopped: node-pool operations fail.
Start it first.

To stop all charges: [destroy.md](destroy.md).
