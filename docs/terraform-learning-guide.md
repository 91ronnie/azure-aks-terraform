# Terraform learning guide (using this repository)

## Mental model

```text
environments/dev      <- root module: "this environment". Has the backend, provider, tfvars.
  main.tf             <- wires modules together
  rbac.tf             <- every permission in one place
  variables.tf        <- inputs (typed, validated)
  outputs.tf          <- what you need after apply (IDs, IPs, commands) - no secrets
  versions.tf         <- Terraform/provider version constraints + backend type
  providers.tf        <- provider configuration (auth comes from the environment)
  tests/              <- `terraform test` with a mocked provider
modules/<name>        <- reusable building blocks; no provider/backend blocks inside
```

* **Provider** (`azurerm ~> 5.12`): plugin that talks to Azure Resource Manager. Pinned by
  constraint; the exact version and checksums are recorded in `.terraform.lock.hcl`, which is
  committed so every machine and pipeline uses identical plugins.
* **Resource**: something Terraform creates and owns (`azurerm_kubernetes_cluster`).
* **Data source**: something Terraform only reads (`azurerm_client_config` = "who am I").
* **Variable**: input. Typed (`list(string)`), with `validation` blocks that fail early
  (try `operator_ip_ranges = ["0.0.0.0/0"]`).
* **Local**: derived value (`local.acr_name`), computed once, used many times.
* **Module**: a folder of `.tf` files called with `module "x" { source = "../../modules/x" }`.
  Its variables are its API; its outputs are its return values.
* **Output**: printed after apply and readable by `terraform output -raw <name>`.
* **State**: Terraform's record of what it created and the real IDs. Stored remotely
  (Azure Blob), locked during operations (blob lease), versioned.

## Dependency graph

Terraform builds a graph from references. Examples in this repo:

* `module.aks` reads `module.identity.kubelet` → identities are created first.
* `module.identity` federated credentials read `module.aks.oidc_issuer_url` → created **after** AKS.
  Modules are not atomic: Terraform orders individual resources, so this two-way module
  reference is fine as long as no resource cycle exists.
* `depends_on` on `module.aks` forces the control-plane role assignments to exist before AKS
  validates its permissions – a dependency Terraform cannot infer from references.

```bash
terraform graph | dot -Tsvg > graph.svg     # needs graphviz
```

## Count/for_each must be known at plan time

`count = var.container_insights_enabled ? 1 : 0` works; `count = var.aks_id == null ? 0 : 1`
fails on first plan because the AKS ID is unknown until apply. The mocked test suite caught a
related bug (inconsistent object types in a `for_each` map) – that is what `terraform test` is for.

## Daily commands

```bash
terraform fmt -recursive            # formatting (CI runs fmt -check)
terraform init -backend=false       # offline init (validation, tests)
terraform validate
terraform test                      # tests/plan.tftest.hcl, mocked provider, no Azure needed
terraform init -backend-config=backend.hcl
terraform plan -out tfplan
terraform show tfplan               # human-readable
terraform show -json tfplan | jq '.resource_changes[] | {address, actions: .change.actions}'
terraform apply tfplan
terraform state list
terraform state show module.aks.azurerm_kubernetes_cluster.this
terraform output -raw acr_login_server
```

## Reading a plan

| Symbol | Meaning | Worry level |
|---|---|---|
| `+` create | new resource | low |
| `~` update in-place | attribute changes on the live resource | read which attribute |
| `-/+` replace | destroy then create (e.g. changing `name`, `location`, `pod_cidr`) | **high** – downtime/data loss |
| `-` destroy | | high |
| `(known after apply)` | value Azure assigns | normal |

Attributes marked `# forces replacement` are the ones to check.

## Remote state, locking, recovery

* Backend `azurerm` with `use_azuread_auth = true`: your Entra ID identity needs *Storage Blob
  Data Contributor* on the container. No access keys.
* Locking: Terraform takes a **blob lease** on the state file during plan/apply. Concurrent runs
  wait (`-lock-timeout=5m`) or fail.
* Recovery: blob versioning + soft delete; see [destroy.md](destroy.md#terraform-state-recovery).
* Migration risk: changing backend settings prompts to copy state. Never answer "yes" without a
  `terraform state pull` backup; never run two backends for the same resources.

## Renaming things safely

* Renaming the **local directory** (`eks-terraform` → `azure-aks-terraform`) changes nothing in
  state: the backend `key` (`frontrow/dev/terraform.tfstate`) and resource addresses don't
  contain the directory name.
* Renaming a **resource address** (e.g. `module.acr` → `module.registry`) would plan a destroy +
  create. Use a `moved {}` block instead:
  ```hcl
  moved {
    from = module.acr
    to   = module.registry
  }
  ```
* Renaming an **Azure resource** (`name = …`) always replaces it.

## Why some things are *not* in Terraform

Kubernetes objects (Argo CD, Traefik, the app) are reconciled by Argo CD. Mixing the Helm/
Kubernetes providers into the same state as the cluster creates ordering problems on create and
destroy (the old EKS repo needed `cluster_created` flags for this). See ADR-008.
