# FrontRow API (Laravel backend) on AKS

The FrontRow API serves the web app at https://azure-fr.frontrow.co.ke. Its public URL is
**https://azure-api.frontrow.co.ke**. It replaces the EC2/CodeDeploy stack described by
`backend/cicd/templates/*.yaml` and `backend/cicd/config/demo-*.json`.

| Was (AWS) | Now (Azure) | Where |
|---|---|---|
| EC2 Auto Scaling + ALB + nginx/php-fpm | AKS Deployment `frontrow-api` (nginx + php-fpm per pod), HPA 2-6 | `gitops/charts/frontrow-api` |
| supervisor `queue:work` programs | Deployment `frontrow-api-worker-default` | chart `workers:` |
| cron `schedule:run` on every instance | Deployment `frontrow-api-scheduler` (1 replica, `schedule:work`) | chart `scheduler:` |
| `migrate --force` in CodeDeploy AfterInstall | Argo CD Sync hook Job `frontrow-api-migrate` (before pods roll) | chart `migrations:` |
| RDS MySQL (`productiondb…`) | MySQL Flexible Server 8.4, private, DBs `frontrow` + `frontrow_mqtt` | `api.tf`, `modules/mysql` |
| ElastiCache/Redis | Azure Managed Redis (Balanced_B0), private endpoint, TLS :10000 | `api.tf`, `modules/managed-redis` |
| S3 buckets (`s3`, `masked_images`, `telemedicine` disks) | Blob containers `files`, `masked-images`, `telemedicine` | `api.tf` |
| SES | Azure Communication Services Email over SMTP | `api.tf` |
| Secrets Manager `<name>/env` → `.env` | Key Vault `kv-api-dev-<suffix>` → CSI driver → env vars | chart `keyVault:` |
| Elasticsearch | **not deployed** (`SCOUT_DRIVER=null`), see [Known gaps](#known-gaps) | |

```
Internet ─► Cloudflare ─► Traefik ─► frontrow-api pod [nginx :8080 ─► php-fpm :9000]
                                         │  workers / scheduler / migrate job (same image)
                                         ├─► MySQL Flexible Server   10.40.13.0/28 :3306  (private)
                                         ├─► Managed Redis (PE)      10.40.8.0/24  :10000 (private)
                                         ├─► Blob storage            public endpoint, private containers, SAS links
                                         ├─► smtp.azurecomm.net:587
                                         └─► Key Vault (CSI, workload identity id-frontrow-dev-api)
```

## First deployment

Run all `az` commands from your own machine. The Key Vault firewall only allows
`operator_ip_ranges`.

### 1. MySQL administrator password (pipeline secret)

The password is **write-only**. Azure receives it, but it is never stored in Terraform state.
Terraform needs it on every plan, because the variable is required when `api_enabled = true`.

```bash
MYSQL_ADMIN_PASSWORD="$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-28)Aa1!"
```

Store the value in two places:

- **Azure DevOps.** In variable group `frontrow-infra-dev`, add a variable `MYSQL_ADMIN_PASSWORD`
  and mark it as a secret (padlock). The infra pipeline maps it to `TF_VAR_mysql_admin_password`.
- **Key Vault.** After step 2, also store it as `mysql-admin-password` in the API Key Vault
  (step 3). It's your break-glass copy.

To rotate it, change the secret, then increment `mysql_admin_password_version` in tfvars and apply.

### 2. Apply the infrastructure

Push to `main` and run the infra pipeline with `runApply=true`. You can also run it locally:

```bash
cd environments/dev
export TF_VAR_mysql_admin_password="$MYSQL_ADMIN_PASSWORD"
terraform plan -out tfplan && terraform apply tfplan
terraform output -json api > /tmp/api.json   # used below
```

New resources: identity and federated credential, Key Vault, MySQL with 2 databases, Managed Redis
with a private endpoint, a storage account with 3 containers, and ACS Email (service, domain,
sender `noreply`).

### 3. Key Vault secrets

Every secret listed under `keyVault.secrets` in the chart must exist. If one is missing, the CSI
mount fails and the pods stay in `ContainerCreating`. Values are piped through stdin, so they never
reach shell history or the process list.

```bash
KV=$(jq -r .key_vault_name /tmp/api.json); RG=rg-frontrow-dev
put() { az keyvault secret set --vault-name "$KV" --name "$1" --file /dev/stdin --output none; }

printf %s "$MYSQL_ADMIN_PASSWORD" | put mysql-admin-password

# Laravel APP_KEY. If you migrate data from AWS, reuse the OLD key instead:
# encrypted columns and signed URLs depend on it.
printf 'base64:%s' "$(openssl rand -base64 32)" | put app-key

# Redis access key (Managed Redis = "redisenterprise" in the CLI)
az redisenterprise database list-keys --cluster-name "$(jq -r .redis_name /tmp/api.json)" -g $RG \
  --query primaryKey -o tsv | tr -d '\n' | put redis-access-key

# Storage account key (needed to sign SAS links, see "Why a storage key")
az storage account keys list -n "$(jq -r .storage_account_name /tmp/api.json)" -g $RG \
  --query '[0].value' -o tsv | tr -d '\n' | put storage-account-key

# Passport OAuth keys. New keys invalidate tokens issued by the old system.
openssl genrsa 4096 2>/dev/null | tee >(put passport-private-key) | openssl rsa -pubout 2>/dev/null | put passport-public-key
```

`db-username`/`db-password` come from step 4, and `smtp-username`/`smtp-password` from step 5.

### 4. Database user

Run this once. The app gets its own user instead of the administrator login. MySQL is reachable
only from inside the VNet, so run the client as a temporary pod. That needs AKS access: you are in
`cluster_admin_object_ids`.

```bash
APP_DB_PASSWORD="$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-28)"
printf frontrow_app | put db-username
printf %s "$APP_DB_PASSWORD" | put db-password

kubectl run mysql-admin --rm -it --restart=Never --image=mysql:8.4 -n default \
  --env=MYSQL_PWD="$MYSQL_ADMIN_PASSWORD" -- \
  mysql -h "$(jq -r .mysql_fqdn /tmp/api.json)" -u frontrowadmin --ssl-mode=REQUIRED -e "
    CREATE USER IF NOT EXISTS 'frontrow_app'@'%' IDENTIFIED BY '$APP_DB_PASSWORD' REQUIRE SSL;
    GRANT ALL PRIVILEGES ON frontrow.* TO 'frontrow_app'@'%';
    GRANT ALL PRIVILEGES ON frontrow_mqtt.* TO 'frontrow_app'@'%';"
```

`kubectl run --env` puts the password into the pod spec for the life of that pod. The pod is
deleted when the command exits (`--rm`).

### 5. Email (Azure Communication Services)

1. **DNS:** add the records from `jq .email_verification_records /tmp/api.json` (domain TXT, SPF,
   DKIM, DKIM2) in Cloudflare as **DNS only**. Then verify them in the portal under Email
   Communication Service → Provision domains → `frontrow.co.ke` → Verify.
2. **Link the domain:** set `api_email_domain_verified = true` and apply. This links the domain
   to `acs-frontrow-dev`.
3. **SMTP credentials:**
   1. Create an Entra app registration (for example `frontrow-api-smtp`) with a client secret.
   2. Give it the role **Communication and Email Service Owner** on `acs-frontrow-dev`.
   3. In the portal, open Communication Service → SMTP Usernames and add a username for that app.
   4. Store the username as `smtp-username` and the client secret as `smtp-password`.

### 6. DNS for the API and GitOps values

1. In Cloudflare, add `azure-api` → the ingress IP (`terraform output -raw ingress_public_ip_address`). This is
   the same IP that `azure-fr` uses.
2. Fill the `REPLACE_ME_*` values in `gitops/environments/dev/frontrow-api/values.yaml` from
   `/tmp/api.json`.
3. Commit. Argo CD creates the `frontrow-api` namespace and syncs. Nothing starts until the
   backend pipeline has written the image block.

### 7. Point the web app at the API

In the web variable group `frontrow-web-dev`:

```
REACT_APP_SERVER_ENDPOINT = https://azure-api.frontrow.co.ke
REACT_APP_ENDPOINT        = https://azure-api.frontrow.co.ke/api
```

These values are compiled into the web bundle, so the web pipeline has to run again.

## Day-2

```bash
kubectl -n frontrow-api get pods,job
kubectl -n frontrow-api logs job/frontrow-api-migrate          # last migration run
kubectl -n frontrow-api logs deploy/frontrow-api -c php --tail=100
kubectl -n frontrow-api exec deploy/frontrow-api -c php -- php artisan queue:failed
kubectl -n frontrow-api rollout restart deploy                 # pick up rotated secrets
```

**Running an artisan command once:** use `kubectl -n frontrow-api exec deploy/frontrow-api -c php -- php artisan <cmd>`.
Seeders and `roles:*` commands that CodeDeploy ran on staging are not automated. Run them this way
when needed.

## Why a storage key

The app returns `temporaryUrl()` links (signed SAS URLs) for images, signatures and reports, and
browsers open them directly. The PHP Azure SDK (`azure-oss/storage-blob` 2.3) signs SAS URLs only
with a shared key. It has no user-delegation SAS, so workload identity can't sign them. As a
result:

- **Account key:** the app uses the account key from Key Vault.
- **Public endpoint:** the storage account keeps its public endpoint, because browsers must reach
  the SAS links.
- **Private containers:** anonymous access is disabled.
- **SAS lifetime:** a `sas_policy` logs any SAS valid for longer than 1 day.

## Known gaps

- **Search and list endpoints are broken.** Elasticsearch is not deployed (a decision made on
  2026-10-30). The patients, appointments, assessments, treatment-orders, organizations and
  audit-log list endpoints build Elasticsearch queries through `app/Http/Filters/Searchable/*`
  (28 files). They fail until those filters are rewritten for SQL.
- **Feature flags** are fetched from a hard-coded AWS Lambda URL
  (`app/FeatureFlags/AppConfigFeatureFlag.php`). That still works from Azure while the Lambda
  exists. Move it to configuration or to Azure App Configuration.
- **HTML→PDF conversion** still calls an AWS API Gateway/Lambda (`AWS_LAMBDA_PDF_CONVERTER_URL`). Rehost it, then
  set the variable in `config:`.
- **MQTT (VerneMQ)** is not part of this deployment. `frontrow_mqtt` (DB2) is created for the
  broker's auth tables, and `REACT_APP_MQTT_HOST` still has to point at a broker.
- **Data:** nothing is copied from AWS. MySQL needs `mysqldump` → `mysql`. Blobs need `azcopy` from
  S3, which keeps object keys, so `file_path` columns stay valid.
