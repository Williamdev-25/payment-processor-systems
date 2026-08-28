# CI/CD Setup

One-time setup required before `ci-cd.yml` can run successfully.

## 1. Bootstrap remote state (run once, manually, before anything else)

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

## 2. AWS OIDC role for GitHub Actions

Create an IAM role trusted by GitHub's OIDC provider (`token.actions.githubusercontent.com`),
scoped to this repo, with permissions to manage the EKS/VPC/ECR resources
this project creates. Store its ARN as the repo secret `AWS_OIDC_ROLE_ARN`.

## 3. Repo secrets

| Secret | Purpose |
|---|---|
| `AWS_OIDC_ROLE_ARN` | The role above |
| `TF_VAR_GRAFANA_ADMIN_PASSWORD` | Grafana login, passed as a Terraform `-var` |
| `TF_VAR_SLACK_WEBHOOK_URL` | Alertmanager's Slack webhook, passed as a Terraform `-var` |

## 4. Repo variable

| Variable | Purpose |
|---|---|
| `APPROVERS` | GitHub username(s) allowed to approve the manual-approval gate |

## Pipeline flow

```
terraform-plan ──┬─→ security-scan ──────┐
                  └─→ test-app ──┬─→ security-scan-images ──┤
                                 │                            ▼
                                 └──────────────────→ manual-approval
                                                              │
                                                              ▼
                                                       deploy-infra
                                                        (terraform apply)
                                                              │
                                                              ▼
                                                      build-and-push
                                                     (ECR, immutable tags)
                                                              │
                                                              ▼
                                                        deploy-app
                                                   (kubectl apply + rollout,
                                                    auto-rollback on failure)
```

Everything up to `manual-approval` runs on every push and PR. Nothing
after that gate runs without a human explicitly commenting `approved`.
