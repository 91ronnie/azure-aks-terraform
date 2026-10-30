# Prerequisites

## Local tools

| Tool | Tested / required version | Install (macOS) |
|---|---|---|
| Azure CLI | 2.6x+ | `brew install azure-cli` |
| Terraform | 1.15.7 (constraint `>= 1.10, < 2.0`) | `brew install hashicorp/tap/terraform` |
| kubectl | within ±1 minor of the cluster | `az aks install-cli` |
| kubelogin | latest | `az aks install-cli` (installs both) |
| Helm | 3.14+ | `brew install helm` |
| jq, yq (mikefarah) | any recent | `brew install jq yq` |
| Docker | 24+ (for local image builds) | Docker Desktop |
| Trivy, Checkov (optional locally) | Trivy 0.7x, Checkov 3.x | `brew install trivy`, `pipx install checkov` |

## Azure

### Subscription and permissions

| Phase | Who | Minimum role(s) | Scope |
|---|---|---|---|
| Bootstrap state backend | You | Contributor + User Access Administrator (to grant yourself blob access) | Subscription (or a pre-created `rg-frontrow-tfstate`) |
| First `terraform apply` | You | **Contributor** + **Role Based Access Control Administrator** | Subscription (the RG is created by Terraform) |
| Normal operation | You | Same as above, but narrowed to `rg-frontrow-dev` once it exists | Resource group |
| Pipeline plan | `sc-frontrow-infra-dev` identity | Reader (+ Storage Blob Data Contributor on the state container – plan takes a lock) | RG + state account |
| Pipeline apply | `sc-frontrow-infra-dev` identity | Contributor + RBAC Administrator **with a condition** limiting assignable roles (below) | `rg-frontrow-dev` |

Terraform creates role assignments (`rbac.tf`), which is why the deploying identity needs
`Microsoft.Authorization/roleAssignments/write`. Avoid Owner: use **Role Based Access Control
Administrator** with an ABAC condition that only allows the roles this repo assigns:
AcrPull, AcrPush, Key Vault Secrets User, Key Vault Secrets Officer, Network Contributor,
Managed Identity Operator, Azure Kubernetes Service RBAC Cluster Admin. (The PostgreSQL
Entra administrator for CrateDigger is set on the server resource itself, not via Azure RBAC.) (Portal: *Access
control → Add role assignment → Role Based Access Control Administrator → Conditions →
"Allow user to only assign selected roles"*.)

### One-time subscription setup

```bash
az login
az account set --subscription "<SUBSCRIPTION_ID>"

# Resource providers used by this repo
for ns in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.KeyVault \
          Microsoft.Network Microsoft.ManagedIdentity Microsoft.OperationalInsights \
          Microsoft.Insights Microsoft.Consumption Microsoft.Storage Microsoft.Compute \
          Microsoft.DBforPostgreSQL; do
  az provider register --namespace "$ns"
done

# Encryption at host for node disks (host_encryption_enabled = true by default)
az feature register --namespace Microsoft.Compute --name EncryptionAtHost
az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state   # wait for "Registered"
az provider register --namespace Microsoft.Compute
```

If you cannot register the feature, set `host_encryption_enabled = false` in `terraform.tfvars`.

### Check region, VM size, quota and Kubernetes versions *before* applying

```bash
LOC=northeurope
# Is the VM size offered in the region without restrictions?
az vm list-skus -l $LOC --size Standard_D2as_v5 --resource-type virtualMachines \
  --query "[].{name:name, restrictions:restrictions}" -o json

# vCPU quota for the family (need 2 per node + 2 for the upgrade surge node)
az vm list-usage -l $LOC --query "[?contains(name.value,'DASv5') || name.value=='cores'].{name:name.localizedValue,used:currentValue,limit:limit}" -o table

# Supported AKS versions (pin one of the non-preview GA versions)
az aks get-versions -l $LOC -o table
```

Free/trial subscriptions often have a regional vCPU limit of 4–10, which is enough for
1–2 nodes plus a surge node.

### Your Entra ID object ID and public IP

```bash
az ad signed-in-user show --query id -o tsv      # → cluster_admin_object_ids
curl -s https://api.ipify.org                    # → operator_ip_ranges ["x.x.x.x/32"]
```

## Azure DevOps

Create these once per project. Nothing below needs a client secret.

### 1. Service connections (Azure Resource Manager → *Workload identity federation*)

| Name | Used by | Scope / roles | Notes |
|---|---|---|---|
| `sc-frontrow-infra-dev` | `azure-pipelines.yml` (infra) | See the permissions table above | Choose "manual" creation if you want to control the app registration / managed identity and its roles yourself |
| `sc-frontrow-acr-push` | `web/azure-pipelines.yml` | **AcrPush on the registry only** | After the first apply, put its principal object ID in `pipeline_acr_push_principal_id` and re-apply; Terraform then owns the assignment |

Disable "Grant access permission to all pipelines" and authorise each connection only for
the pipeline that needs it.

### 2. Variable groups (Pipelines → Library) – non-secret values only

`frontrow-infra-dev`

| Variable | Example |
|---|---|
| `ARM_SUBSCRIPTION_ID` | `0000…` |
| `TFSTATE_RESOURCE_GROUP` | `rg-frontrow-tfstate` |
| `TFSTATE_STORAGE_ACCOUNT` | `stfrontrowtfstate<suffix>` |
| `TFSTATE_CONTAINER` | `tfstate` |
| `TFSTATE_KEY` | `frontrow/dev/terraform.tfstate` |
| `TF_VAR_unique_suffix`, `TF_VAR_owner` | as in tfvars |
| `TF_VAR_operator_ip_ranges` | `["203.0.113.10/32"]` (HCL list syntax) |
| `TF_VAR_cluster_admin_object_ids` | `["<object-id>"]` |
| `TF_VAR_pipeline_acr_push_principal_id` | `<object-id>` |

`frontrow-web-dev`: see `web/docs/deployment.md#azure-devops-setup`.

### 3. Environment with approval

Pipelines → Environments → **New environment** `frontrow-infra-dev` → *Approvals and checks*
→ **Approvals** (you, or a group) → optionally *Branch control* = `refs/heads/main`.

### 4. Repository permissions for GitOps

Project settings → Repositories → *<infra repo>* → Security →
`<Project> Build Service (<org>)` → **Contribute: Allow** (and nothing else). This lets the
web pipeline commit the image tag. If `main` has branch policies that require PRs, either grant
"Bypass policies when pushing" to that identity **on this repository only**, or change the
GitOps step to open a PR (recommended for production).

Also set Project settings → Pipelines → Settings → "Limit job authorization scope to current
project" **on**, and "Protect access to repositories in YAML pipelines" **on**.

### 5. Branch policy (build validation)

Repos → Branches → `main` → Branch policies → Build validation → add the infra pipeline
(for the infra repo) and the web pipeline (for the app repo). Azure Repos ignores the YAML
`pr:` block; this policy is what runs validation on pull requests.

## Cloudflare

* The `frontrow.co.ke` zone already exists in your Cloudflare account and is authoritative.
* You need permission to add DNS records and change SSL/TLS settings for the zone.
* No API token is needed for this setup (DNS is changed manually and deliberately).
