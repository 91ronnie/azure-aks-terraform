# Hands-on exercises

Each exercise lists the goal, steps and what you should observe. Do them in the dev lab.

## 1. Change the node size and inspect the plan

```bash
cd environments/dev
terraform plan -var node_vm_size=Standard_B2as_v2 -out tfplan
terraform show tfplan | grep -B2 -A6 vm_size
```

Observe: `~ update in-place` on `module.aks.azurerm_kubernetes_cluster.this` with
`default_node_pool[0].vm_size` changing. Because `temporary_name_for_rotation` is set, AKS
creates `systemtmp`, moves pods, rebuilds `system`. Without it, the provider would need to
replace the cluster. Questions: how long would pods be unavailable? (PDB + 2 replicas → none
for FrontRow, brief for single-replica add-ons.) Discard: `rm tfplan`.

## 2. Explain a subnet CIDR change

Change `aks_nodes_subnet_cidr = "10.40.4.0/22"` and plan.

Observe what the plan proposes for `module.networking.azurerm_subnet.aks_nodes` (in-place `~`
or replace `-/+`) and which other resources reference it. Then reason about what Azure would
do: a subnet whose address range no longer contains its attached node NICs cannot be changed
in place, and re-creating it requires the cluster's node pool to move. Lesson: node subnet and
pod/service CIDRs are effectively fixed for a running cluster – plan them up front
([architecture.md#ip-plan](architecture.md#ip-plan)). Repeat with `pod_cidr` and note whether
the plan marks `# forces replacement` on the cluster. Compare with **adding** a new subnet in
the reserved space (pure create, no impact). Don't apply any of these.

## 3. Trace an image from build to pod

1. Pipeline run → *Image* stage log → find `Pushed …:git-<sha>@sha256:<digest>`.
2. ACR: `az acr manifest list-metadata -r <acr> -n frontrow/web --orderby time_desc -o table`
3. GitOps: `git log -1 -- gitops/environments/dev/frontrow/values.yaml` → same tag + digest.
4. Argo CD: `kubectl -n argocd get app frontrow-dev -o jsonpath='{.status.sync.revision}'` = that commit.
5. Pod: `kubectl -n frontrow get pod -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'` = same digest.
6. Runtime: `curl https://azure-fr.frontrow.co.ke/build-info.json` → `gitSha` = source commit.

## 4. Troubleshoot a failed Argo CD reconciliation

Break it on purpose in a branch you then push to `main` of a *lab* repo:
set `image.tag: latest` in the dev values.

Observe: `frontrow-dev` → `ComparisonError … image.tag must be an immutable tag`. Find it with
`kubectl -n argocd get app frontrow-dev -o jsonpath='{.status.conditions}'`. Fix with `git revert`.
Second variant: point `image.tag` to a tag that does not exist → Synced but `Degraded`
(`ImagePullBackOff`). Note the difference between *sync* errors (render/apply) and *health*
errors (runtime).

## 5. Rotate a test Key Vault secret

1. Create it: `az keyvault secret set --vault-name <kv> -n frontrow-demo-secret --value v1`
2. In `gitops/environments/dev/frontrow/values.yaml` enable `keyVault` (name, tenantId, objects)
   and `serviceAccount.workloadIdentityClientId` from `terraform output`. Commit, push.
3. `kubectl -n frontrow exec deploy/frontrow -- cat /mnt/secrets/frontrow-demo-secret` → `v1`
4. Set `v2` in Key Vault; within ~2 minutes the file shows `v2` (no restart).
5. Disable `keyVault` again when done (FrontRow doesn't need it).

## 6. Investigate a failed vulnerability scan

Temporarily change `NGINX_IMAGE` in `web/Dockerfile` to an old tag (e.g. `nginxinc/nginx-unprivileged:1.24-alpine`)
on a branch and run the pipeline (the push stage is skipped off `main`).

Observe: *Trivy image scan* fails listing CVEs with `Fixed Version`. Practise the triage in
`docs/security.md#handling-a-finding`: identify the package, the layer (OS vs npm), the fix.
Revert the change; never add the IDs to `.trivyignore` to get a green build.

## 7. Roll back to a previous image

```bash
git log --oneline -5 -- gitops/environments/dev/frontrow/values.yaml
git revert --no-edit <latest-bump-sha> && git push
kubectl -n frontrow rollout status deploy/frontrow
curl -s https://azure-fr.frontrow.co.ke/build-info.json
```

The previous image still exists in ACR (that's why purging keeps the newest 10 tags).

## 8. Destroy and recreate the lab safely

Follow [destroy.md](destroy.md) Option 2, then *Recreate safely*. Note what changed afterwards:
ingress IP (Cloudflare record), identity client IDs, Key Vault name (if within retention).
Timing to note: destroy ~10 min, apply ~15 min, Argo CD bootstrap ~5 min, certificate ~2 min.
