#!/usr/bin/env bash
# Pré-requisitos: AWS CLI autenticado, gh autenticado e jq.

set -euo pipefail

OWNER="${GITHUB_OWNER:-Guilherme-Fumagali}"
REVISORES="${REVISORES:-Guilherme-Fumagali kanatu}"
PROVIDER_HOST="token.actions.githubusercontent.com"
BOUNDARY_NAME="oficina-lambda-boundary"
IAM_DIR="$(cd "$(dirname "$0")" && pwd)/iam"

REPOS=(
  "tech-challenge-1|oficina-api-github-actions|prod"
  "oficina-auth-lambda|oficina-auth-lambda-github-actions|prod"
  "oficina-infra-db|oficina-infra-db-github-actions|prod"
  "oficina-infra-k8s|oficina-infra-k8s-github-actions|base prod"
)
AMBIENTES_COM_REVISOR="oficina-infra-db/prod oficina-infra-k8s/prod"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

for bin in aws gh jq; do
  command -v "$bin" >/dev/null || die "$bin não encontrado no PATH."
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "AWS CLI não está autenticado."
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${PROVIDER_HOST}"

documento() { sed "s/ACCOUNT_ID/${ACCOUNT_ID}/g" "${IAM_DIR}/$1.json"; }

garantir_provider() {
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
    log "Identity Provider OIDC já existe."
    return
  fi
  log "Criando Identity Provider OIDC do GitHub..."
  aws iam create-open-id-connect-provider \
    --url "https://${PROVIDER_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
}

garantir_boundary() {
  local arn="arn:aws:iam::${ACCOUNT_ID}:policy/${BOUNDARY_NAME}" versao
  if ! aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    log "Criando permissions boundary $BOUNDARY_NAME..."
    aws iam create-policy --policy-name "$BOUNDARY_NAME" \
      --policy-document "$(documento "$BOUNDARY_NAME")" >/dev/null
    return
  fi
  log "Atualizando permissions boundary $BOUNDARY_NAME..."
  for versao in $(aws iam list-policy-versions --policy-arn "$arn" \
      --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$versao"
  done
  aws iam create-policy-version --policy-arn "$arn" --set-as-default \
    --policy-document "$(documento "$BOUNDARY_NAME")" >/dev/null
}

trust_policy() {
  local repo="$1" ambientes="$2" prefixo
  prefixo="$(gh api "repos/${OWNER}/${repo}/actions/oidc/customization/sub" -q '.sub_claim_prefix // empty')"
  prefixo="${prefixo:-repo:${OWNER}/${repo}}"

  jq -n --arg provider "$PROVIDER_ARN" --arg host "$PROVIDER_HOST" \
        --arg prefixo "$prefixo" --arg ambientes "$ambientes" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: { Federated: $provider },
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {
        StringEquals: {
          ($host + ":aud"): "sts.amazonaws.com",
          ($host + ":sub"): (
            [$prefixo + ":ref:refs/heads/main"]
            + ($ambientes | split(" ") | map($prefixo + ":environment:" + .))
          )
        }
      }
    }]
  }'
}

garantir_role() {
  local repo="$1" role="$2" ambientes="$3" trust
  trust="$(trust_policy "$repo" "$ambientes")"

  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    log "Role $role já existe — atualizando a trust policy."
    aws iam update-assume-role-policy --role-name "$role" --policy-document "$trust"
  else
    log "Criando role $role..."
    aws iam create-role --role-name "$role" \
      --description "GitHub Actions de ${OWNER}/${repo}" \
      --assume-role-policy-document "$trust" >/dev/null
  fi

  aws iam put-role-policy --role-name "$role" --policy-name menor-privilegio \
    --policy-document "$(documento "$role")"

  if aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[].PolicyName' --output text | grep -qw AdministratorAccess; then
    log "Removendo AdministratorAccess de $role..."
    aws iam detach-role-policy --role-name "$role" \
      --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"
  fi

  gh secret set AWS_ROLE_ARN --repo "${OWNER}/${repo}" \
    --body "arn:aws:iam::${ACCOUNT_ID}:role/${role}"
}

garantir_ambiente() {
  local repo="$1" ambiente="$2" revisores='[]' login
  if [[ " $AMBIENTES_COM_REVISOR " == *" ${repo}/${ambiente} "* ]]; then
    revisores="$(for login in $REVISORES; do
      gh api "users/${login}" -q '{type: "User", id: .id}'
    done | jq -s -c .)"
  fi

  log "Environment ${repo}/${ambiente}: só main, revisores=$(jq -r 'length' <<<"$revisores")."
  jq -n --argjson revisores "$revisores" '{
    reviewers: $revisores,
    deployment_branch_policy: { protected_branches: false, custom_branch_policies: true }
  }' | gh api -X PUT "repos/${OWNER}/${repo}/environments/${ambiente}" --input - >/dev/null

  if ! gh api "repos/${OWNER}/${repo}/environments/${ambiente}/deployment-branch-policies" \
      -q '.branch_policies[].name' | grep -qx main; then
    gh api -X POST "repos/${OWNER}/${repo}/environments/${ambiente}/deployment-branch-policies" \
      -f name=main -f type=branch >/dev/null
  fi
}

log "Conta AWS: $ACCOUNT_ID | Owner GitHub: $OWNER"
garantir_provider
garantir_boundary

for entrada in "${REPOS[@]}"; do
  IFS='|' read -r repo role ambientes <<<"$entrada"
  for ambiente in $ambientes; do
    garantir_ambiente "$repo" "$ambiente"
  done
  garantir_role "$repo" "$role" "$ambientes"
done

gh variable set API_DEPLOY_ROLE_ARN --repo "${OWNER}/oficina-infra-k8s" \
  --body "arn:aws:iam::${ACCOUNT_ID}:role/oficina-api-github-actions"

log "Pronto. Cada repositório assume só a própria role, só a partir da main ou de environment restrito à main."
