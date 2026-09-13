#!/usr/bin/env bash
# Pré-requisitos: AWS CLI autenticado (`aws configure` ou `aws sso login`).
#
# Uso:
#   ./github-oidc.sh                       # repo default abaixo
#   GITHUB_REPO=owner/repo ./github-oidc.sh

set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-Guilherme-Fumagali/tech-challenge-1}"
ROLE_NAME="${ROLE_NAME:-oficina-api-github-actions}"
PROVIDER_HOST="token.actions.githubusercontent.com"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || die "AWS CLI não encontrado no PATH."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "AWS CLI não está autenticado. Rode 'aws configure' antes."
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${PROVIDER_HOST}"

log "Conta AWS: $ACCOUNT_ID | Repo autorizado: $GITHUB_REPO"

# ── 1. Identity Provider OIDC ────────────────────────────────────────────────
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  log "Identity Provider OIDC já existe."
else
  log "Criando Identity Provider OIDC do GitHub..."
  aws iam create-open-id-connect-provider \
    --url "https://${PROVIDER_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
fi

# ── 2. IAM role assumível só por este repo ───────────────────────────────────
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "${PROVIDER_HOST}:aud": "sts.amazonaws.com" },
      "StringLike":   { "${PROVIDER_HOST}:sub": "repo:${GITHUB_REPO}:*" }
    }
  }]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log "Role $ROLE_NAME já existe — atualizando a trust policy."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
else
  log "Criando role $ROLE_NAME..."
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "Deploy do oficina-api via GitHub Actions (Tech Challenge Fase 2)" \
    --assume-role-policy-document "$TRUST_POLICY" >/dev/null
fi

log "Anexando AdministratorAccess..."
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAMEn" --query 'Role.Arn' --output text)"

cat <<EOF

┌──────────────────────────────────────────────────────────────────────────────
│ Pronto. Agora, no GitHub:
│
│   Settings → Secrets and variables → Actions → New repository secret
│     Nome:  AWS_ROLE_ARN
│     Valor: ${ROLE_ARN}
│
│ E crie também os secrets: TF_VAR_DB_PASSWORD, TF_VAR_JWT_SECRET (>=32 chars),
│ TF_VAR_ADMIN_PASSWORD.
│
│ Depois disso, tudo roda pelo Actions — um push em main dispara o workflow "Terraform".
└──────────────────────────────────────────────────────────────────────────────
EOF
