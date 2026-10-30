# GitOps configuration

Everything Argo CD deploys into the AKS cluster. Terraform does not touch this folder; the
infrastructure pipeline ignores changes here.

| Path | Who changes it | How |
|---|---|---|
| `argocd/` | you | PR; re-run `install-argocd.sh` for Argo CD itself |
| `apps/dev/` | you | PR; Argo CD picks it up via `root-dev` |
| `platform/dev/` | you | PR |
| `charts/frontrow/` | you / app developers | PR; validate with `helm lint` + `helm template` |
| `environments/dev/frontrow/values.yaml` | **web pipeline** (image block), you (rest) | automatic commit `***NO_CI***` / PR |
| `charts/frontrow-api/` | you / backend developers | PR; validate with `helm lint` + `helm template` |
| `environments/dev/frontrow-api/values.yaml` | **backend pipeline** (image blocks), you (rest) | automatic commit `***NO_CI***` / PR; runbook: [../docs/frontrow-api.md](../docs/frontrow-api.md) |

Before first use replace every `REPLACE_ME_*` placeholder (repo URL, ACME email):
`grep -rn REPLACE_ME .`

Full guide: [../docs/argocd-gitops.md](../docs/argocd-gitops.md).
