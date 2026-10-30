# Argo CD, Helm and GitOps

## Layout

```text
gitops/
├── argocd/
│   ├── install-argocd.sh          # helm upgrade --install (pinned chart) + projects + root app
│   ├── values.yaml                # Argo CD Helm values (lab profile)
│   ├── projects.yaml              # AppProjects: platform, frontrow
│   ├── root-app.yaml              # app-of-apps -> gitops/apps/dev
│   └── repository.example.yaml    # how to create the repo credential (never commit a real one)
├── apps/dev/                      # one Argo CD Application per file
│   ├── traefik.yaml               # wave 0, chart from traefik.github.io (pinned)
│   ├── cert-manager.yaml          # wave 0, chart from charts.jetstack.io (pinned)
│   ├── platform-config.yaml       # wave 1, gitops/platform/dev (ClusterIssuers)
│   └── frontrow.yaml              # wave 2, gitops/charts/frontrow + environments/dev values
├── platform/dev/cluster-issuers.yaml
├── charts/frontrow/               # the application Helm chart
└── environments/dev/frontrow/values.yaml   # <- the only file the web pipeline edits
```

## Why GitOps here

* The pipeline needs **no Kubernetes credentials**. It pushes an image and edits a YAML file.
* The cluster converges to Git: manual `kubectl edit` on managed objects is reverted
  (`selfHeal: true`), deletions in Git are applied (`prune: true`).
* Rollback = revert a commit.

## Bootstrap

See [deployment-runbook.md §6](deployment-runbook.md#6-bootstrap-argo-cd). Sequence inside the
cluster after `install-argocd.sh`:

1. `root-dev` syncs `gitops/apps/dev` → creates four Applications.
2. Wave 0: Traefik (gets the static IP), cert-manager (+ CRDs).
3. Wave 1: ClusterIssuers (retry with back-off until the cert-manager webhook is ready).
4. Wave 2: FrontRow (fails to render until the first image reference exists – expected).

## Repository access for Argo CD

| Option | Secret material | Notes |
|---|---|---|
| **A. Workload identity** (preferred) | none | Identity `id-frontrow-dev-argocd` (Terraform) federated to the Argo CD service accounts; add it to the Azure DevOps organisation with Reader on the repo; repo secret with `useAzureWorkloadIdentity: "true"`. Confirm your Argo CD version documents Azure DevOps workload identity before relying on it |
| B. Read-only PAT | PAT (Code: Read), in a Kubernetes Secret created by hand | Simple; set the shortest practical expiry and a calendar reminder to rotate |
| C. SSH deploy key | private key in a Kubernetes Secret | Azure DevOps SSH keys are user-scoped, so prefer A or B |

## Accessing the UI

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080 - admin / password from argocd-initial-admin-secret
```

After first login: *User info → Update password*, then delete `argocd-initial-admin-secret`.
Production: configure Entra ID SSO (OIDC) and set `admin.enabled: "false"`.

## Helm chart (gitops/charts/frontrow)

| Template | Purpose | Key settings |
|---|---|---|
| `deployment.yaml` | nginx pods | `repo:tag@digest`, probes on `/healthz`, non-root, read-only FS, emptyDir `/tmp`, topology spread |
| `service.yaml` | ClusterIP :80 → :8080 | |
| `ingress.yaml` | Traefik Ingress + cert-manager annotation | host from values |
| `serviceaccount.yaml` | `frontrow` SA | token automount off; workload identity annotation only when Key Vault is on |
| `hpa.yaml` | CPU-based 2–4 replicas | |
| `pdb.yaml` | `minAvailable: 1` | only rendered when ≥2 replicas are guaranteed |
| `networkpolicy.yaml` | ingress from `traefik` ns only, no egress | |
| `secretproviderclass.yaml` | Key Vault CSI mount | off by default |
| `_helpers.tpl` | names, labels, image reference | fails on empty tag or `latest` |

There is no ConfigMap: FrontRow's configuration is compiled into the static build, and nginx's
config ships inside the image (`web/nginx/default.conf`), so a ConfigMap would only duplicate it.

Validate locally:

```bash
helm lint gitops/charts/frontrow -f gitops/charts/frontrow/ci/test-values.yaml --strict
helm template frontrow gitops/charts/frontrow -n frontrow --kube-version 1.34.0 \
  -f gitops/environments/dev/frontrow/values.yaml \
  --set image.repository=x.azurecr.io/frontrow/web,image.tag=git-abc123 | less
```

## Promotion

| Environment | How a new image gets there |
|---|---|
| dev | Automatic: web pipeline on `main` commits `image.{repository,tag,digest}` with `***NO_CI***` |
| prod (future) | Copy the **same tag + digest** into `environments/prod/…/values.yaml` by pull request; approval = PR review. Note: `REACT_APP_*` values are baked in at build time, so a prod build needs prod values – either build per environment or move to runtime config (`/env.js`) first |

Loop prevention: the GitOps commit carries `***NO_CI***`; the infra pipeline's trigger excludes
`gitops/*`; the web pipeline only triggers on `web/*` in its own repository.

## Rollback

```bash
git log --oneline -- gitops/environments/dev/frontrow/values.yaml   # find the bad bump
git revert <sha> && git push                                        # Argo CD rolls back in <= 3 min
```

Emergency (bypasses Git, Argo CD will revert it on next sync unless you disable auto-sync):
`kubectl -n argocd patch app frontrow-dev --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`
then `argocd app rollback` / `kubectl rollout undo`. Re-enable auto-sync after fixing Git.

## Drift and reconciliation troubleshooting

```bash
kubectl -n argocd get app frontrow-dev -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n argocd get app frontrow-dev -o jsonpath='{.status.conditions}' | jq
kubectl -n argocd logs deploy/argocd-repo-server --tail=50       # Git/Helm render errors
kubectl -n argocd logs statefulset/argocd-application-controller --tail=50
kubectl -n argocd annotate app frontrow-dev argocd.argoproj.io/refresh=hard --overwrite
```

| Symptom | Likely cause |
|---|---|
| `ComparisonError … authentication required` | Repo credential missing/expired (PAT) or identity not added to Azure DevOps |
| `image.repository is required` | No pipeline run yet, or the GitOps commit failed |
| `OutOfSync` that flips back | Something else mutates the object (HPA vs `replicas` – the chart omits `replicas` when HPA is on) |
| `Degraded`, pods `ImagePullBackOff` | Kubelet lacks AcrPull, wrong registry name, or tag not pushed |
| Pods rejected: `violates PodSecurity "restricted"` | A chart change removed a security setting |

## Argo CD upgrades

1. Read the Argo CD release notes for every minor version you cross.
2. Change `CHART_VERSION` in `install-argocd.sh`; diff first:
   `helm diff upgrade …` (plugin) or `helm template` old/new and compare.
3. Run the script. Applications keep running during the upgrade.
