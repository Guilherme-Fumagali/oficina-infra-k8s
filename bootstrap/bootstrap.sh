#!/usr/bin/env bash
#
# Backend de state do Terraform: bucket S3 + tabela DynamoDB de lock. Idempotente.
#
# Uso:
#   ./bootstrap.sh create    # cria bucket + tabela
#   ./bootstrap.sh destroy   # remove os dois (rode DEPOIS de destruir o ambiente aws)

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
LOCK_TABLE="${TFSTATE_LOCK_TABLE:-oficina-api-tfstate-lock}"
STATE_KEYS="infra-k8s/base/terraform.tfstate infra-k8s/cluster/terraform.tfstate infra-db/prod/terraform.tfstate"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || die "AWS CLI não encontrado no PATH."

# Nome derivado da conta: sufixo -an usa o account regional namespace (nome reservado à conta).
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "AWS CLI não está autenticado."
BUCKET="${TFSTATE_BUCKET:-oficina-api-tfstate-${ACCOUNT_ID}-${AWS_REGION}-an}"

bucket_exists() { aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; }
table_exists()  { aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; }

create() {
  if bucket_exists; then
    log "Bucket s3://$BUCKET já existe — nada a criar."
  else
    log "Criando bucket s3://$BUCKET em $AWS_REGION..."
    local ns_flag=()
    case "$BUCKET" in
      *-an) ns_flag=(--bucket-namespace account-regional) ;;
    esac

    # us-east-1 rejeita LocationConstraint (é o default da API).
    if [ "$AWS_REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" "${ns_flag[@]}"
    else
      aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
        --create-bucket-configuration "LocationConstraint=$AWS_REGION" "${ns_flag[@]}"
    fi
    aws s3api wait bucket-exists --bucket "$BUCKET"
  fi

  # PUTs idempotentes: rodam sempre, também corrigem bucket criado à mão sem proteções.
  log "Habilitando versionamento (permite recuperar um state corrompido)..."
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  log "Habilitando criptografia em repouso (AES256)..."
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  log "Bloqueando acesso público (o state contém endpoints e metadados da infra)..."
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  if table_exists; then
    log "Tabela DynamoDB $LOCK_TABLE já existe — nada a criar."
  else
    log "Criando tabela DynamoDB $LOCK_TABLE (lock de state, PAY_PER_REQUEST)..."
    aws dynamodb create-table \
      --table-name "$LOCK_TABLE" \
      --region "$AWS_REGION" \
      --billing-mode PAY_PER_REQUEST \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH >/dev/null
    aws dynamodb wait table-exists --table-name "$LOCK_TABLE" --region "$AWS_REGION"
  fi

  log "Backend pronto: bucket=$BUCKET, table=$LOCK_TABLE."
}

# Aborta se o state ainda tem recursos: apagar o bucket agora orfanaria EKS/RDS (cobrando).
assert_state_vazio() {
  local key tmp recursos
  for key in $STATE_KEYS; do
    if ! aws s3api head-object --bucket "$BUCKET" --key "$key" >/dev/null 2>&1; then
      log "Sem state em s3://$BUCKET/$key."
      continue
    fi
    tmp="$(mktemp)"
    aws s3api get-object --bucket "$BUCKET" --key "$key" "$tmp" >/dev/null
    recursos="$(jq '[.resources[]?] | length' "$tmp")"
    rm -f "$tmp"
    if [ "$recursos" -gt 0 ]; then
      die "O state $key ainda tem $recursos recurso(s) — infra provavelmente de pé (cobrando).
     Rode o workflow 'Destroy AWS' para cada stack ANTES deste. Se a conta já está limpa
     (conferido no console), force com: FORCE_DESTROY=1 ./bootstrap.sh destroy"
    fi
    log "State $key vazio (0 recursos)."
  done
  log "Nenhum state com recursos — seguro destruir o backend."
}

destroy() {
  command -v jq >/dev/null || die "jq não encontrado no PATH (necessário só para o destroy)."

  if [ "${FORCE_DESTROY:-0}" = "1" ]; then
    log "FORCE_DESTROY=1 — pulando a verificação de state órfão."
  else
    assert_state_vazio
  fi

  if bucket_exists; then
    log "Esvaziando s3://$BUCKET (todas as versões e delete markers)..."
    # Bucket versionado só é deletável com TODAS as versões removidas — não basta `rm`.
    while :; do
      local objetos qtd payload
      objetos="$(aws s3api list-object-versions --bucket "$BUCKET" --output json \
        | jq -c '[(.Versions // []), (.DeleteMarkers // [])] | flatten | map({Key, VersionId})')"
      qtd="$(echo "$objetos" | jq 'length')"
      [ "$qtd" -eq 0 ] && break

      payload="$(mktemp)"
      echo "$objetos" | jq -c '.[0:1000] | {Objects: ., Quiet: true}' > "$payload"
      aws s3api delete-objects --bucket "$BUCKET" --delete "file://$payload" >/dev/null
      rm -f "$payload"
    done

    log "Deletando bucket s3://$BUCKET..."
    aws s3api delete-bucket --bucket "$BUCKET" --region "$AWS_REGION"
  else
    log "Bucket s3://$BUCKET não existe — nada a deletar."
  fi

  if table_exists; then
    log "Deletando tabela DynamoDB $LOCK_TABLE..."
    aws dynamodb delete-table --table-name "$LOCK_TABLE" --region "$AWS_REGION" >/dev/null
    aws dynamodb wait table-not-exists --table-name "$LOCK_TABLE" --region "$AWS_REGION"
  else
    log "Tabela $LOCK_TABLE não existe — nada a deletar."
  fi

  log "Backend removido. A conta AWS não deve ter mais nenhum recurso deste projeto."
}

case "${1:-}" in
  create)  create ;;
  destroy) destroy ;;
  *)       die "Uso: $0 {create|destroy}" ;;
esac
