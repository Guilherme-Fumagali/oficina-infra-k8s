# oficina-infra-k8s

Infraestrutura de **rede, cluster Kubernetes, registry, API Gateway e observabilidade** do Tech Challenge Fase 3 — PosTech FIAP, Arquitetura de Software.

Um dos quatro repositórios da entrega. Os outros: `oficina-api` (aplicação), `oficina-auth-lambda` (autenticação por CPF) e `oficina-infra-db` (RDS).

## Propósito

Provisiona por Terraform tudo que fica entre a internet e a aplicação: a VPC com subnets privadas, o cluster EKS com escalabilidade, o registry ECR, o API Gateway que protege as rotas sensíveis, e os dashboards e alertas do New Relic.

**Este repositório é dono da rede.** Os outros três consomem VPC, subnets e security groups a partir dele, pelo SSM Parameter Store.

## Arquitetura

```
                            Internet
                                │
                    ┌───────────▼────────────┐
                    │   API Gateway HTTP API │
                    └──┬──────────────────┬──┘
         POST /auth    │                  │  ANY /api/{proxy+}
                       │                  │  (Lambda authorizer, cache 300s)
              ┌────────▼──────┐    ┌──────▼────────┐
              │ Lambda        │    │  VPC Link     │
              │ (outro repo)  │    └──────┬────────┘
              └───────────────┘           │
   ┌──────────────────────────────────────┼─────────────────────────────┐
   │ VPC 10.0.0.0/16                      │                             │
   │                                      │                             │
   │  subnet PÚBLICA 10.0.1.0/24 · 10.0.2.0/24                          │
   │     └── NAT instance t4g.nano (+EIP) ──────────▶ internet          │
   │                                      │                             │
   │  subnet PRIVADA 10.0.11.0/24 · 10.0.12.0/24                        │
   │     ├── NLB interno ─────────────────┘                             │
   │     │      └──▶ NodePort 30080 ──▶ EKS ──▶ oficina-api (HPA 2–4)   │
   │     ├── nós EKS (t3.small ×2, sem IP público)                      │
   │     └── RDS (repo oficina-infra-db)                                │
   │                                                                    │
   │  S3 gateway endpoint (grátis) ──▶ camadas de imagem do ECR         │
   └────────────────────────────────────────────────────────────────────┘
                                  │
                       telemetria pela NAT
                                  ▼
                             New Relic
```

## Tecnologias

- **Terraform 1.9.8** · providers AWS ~> 5.70, New Relic ~> 3.48
- **Amazon EKS 1.36** · node group gerenciado · **HPA** por CPU e memória
- **Amazon ECR** com scan on push e lifecycle policy
- **API Gateway HTTP API** + VPC Link + Network Load Balancer interno
- **New Relic** — dashboards, alert conditions e monitor sintético, tudo em código
- Backend de state em **S3 + DynamoDB**

## O que é provisionado

| Grupo | Recursos |
|---|---|
| Rede | VPC, 2 subnets públicas, 2 privadas, IGW, **NAT instance `t4g.nano`**, route tables, **S3 gateway endpoint**, SG da Lambda |
| Cluster | EKS 1.36, node group `t3.small` ×2 (max 4) **em subnet privada**, IAM roles, access entries |
| Registry | ECR `oficina-api` + lifecycle de 10 imagens |
| Borda | HTTP API, VPC Link, NLB interno, target group no NodePort 30080, authorizer, stage com access log |
| Observabilidade | 6 alert conditions, monitor sintético, 2 dashboards |
| Orçamento | AWS Budget de US$ 50 com alerta de **previsão** |
| Contrato | 12 parâmetros no SSM para os outros repositórios |

## Decisões de rede — e a conta

A Fase 2 rodava tudo em subnet pública. A Aula 04 de Serverless é explícita: banco exposto publicamente é risco grave mesmo com senha forte, e API sem autenticação em subnet pública pode ser descoberta pelo IP e atacada.

Para dar saída de internet a recursos privados havia três caminhos, em `us-east-1` com **2 AZs**:

| Opção | Conta | US$/mês |
|---|---|---|
| NAT Gateway | US$ 0,045/h | ~33 |
| VPC interface endpoints | US$ 0,01/h × 4 endpoints × 2 AZs | ~58 |
| **NAT instance `t4g.nano` + EIP** | US$ 0,0042/h + US$ 0,005/h | **~7** |

Interface endpoints são cobrados **por endpoint e por AZ** — saem mais caros que o NAT Gateway. E não resolveriam: a telemetria do New Relic vai para `collector.newrelic.com`, endpoint público que nenhum interface endpoint atende.

Efeito colateral que economiza: em subnet privada os nós deixam de ter IPv4 público, cobrado desde fevereiro de 2024. **US$ 7,30/mês** que estavam sendo gastos à toa.

> **Limitação aceita:** a NAT instance é ponto único de falha, numa AZ. Se cair, telemetria para de fluir e pull de imagem falha. Impacto é perda de observabilidade, não indisponibilidade da API. Registrado como débito técnico.

## Duas stacks, dois custos

| Stack | Recursos | Custo | Quando aplica |
|---|---|---|---|
| **`base/`** | ECR, parâmetros SSM (`ecr-repository-url`, `jwt-secret`, `newrelic-license-key`) | centavos/mês | automático no merge em `main` |
| **`cluster/`** | VPC, NAT, EKS, NLB, API Gateway, New Relic, manifests | ~US$ 0,20/h | **só por `workflow_dispatch`**, com aprovação |

A `base` fica de pé o tempo todo: a pipeline da aplicação precisa do ECR para publicar imagem, e o custo é irrelevante. O `cluster` sobe para validar e apresentar, e é destruído depois — push em `main` nunca o aciona.

## Acesso da pipeline à AWS

Sem chave de acesso: cada repositório assume **a própria role** por OIDC, criada por `bootstrap/github-oidc.sh`.

| Repositório | Role | Pode |
|---|---|---|
| `oficina-api` | `oficina-api-github-actions` | push no ECR `oficina-api`, ler 2 parâmetros do SSM, editar o namespace `oficina` |
| `oficina-auth-lambda` | `oficina-auth-lambda-github-actions` | stack SAM, funções `oficina-auth*`, roles só com o boundary `oficina-lambda-boundary` |
| `oficina-infra-db` | `oficina-infra-db-github-actions` | RDS `oficina-api-db-*`, security group e parâmetros `/oficina/*` |
| `oficina-infra-k8s` | `oficina-infra-k8s-github-actions` | rede, EKS, NLB, API Gateway, ECR, budget e roles `oficina-api-eks-*` |

A trust policy só aceita token da `main` ou de environment (`base`, `prod`) restrito à `main`; `prod` dos repositórios de infra exige revisor. Branch de feature roda validação, nunca credencial.

## Execução

Pré-requisitos: Terraform 1.9.8+, AWS CLI, `kubectl` e credenciais.

```bash
cd base
terraform init -backend-config="key=infra-k8s/base/terraform.tfstate"
terraform apply -var="jwt_secret=$JWT_SECRET"

cd ../cluster
terraform init -backend-config="key=infra-k8s/cluster/terraform.tfstate"
terraform apply
```

Verificação sem credenciais, em cada stack:

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
```

### Os dois applies do cluster

Há uma dependência circular: o gateway precisa do ARN da Lambda, e a Lambda precisa da rede criada aqui. Resolvida em duas passagens:

```bash
# 1º apply — rede, EKS, gateway sem as rotas da Lambda
terraform apply

# ... sobem oficina-infra-db, oficina-api e oficina-auth-lambda ...

# 2º apply — agora com as rotas e os manifests
terraform apply -var="enable_lambda_routes=true" -var="aplicar_manifests=true"
```

**É o passo que mais confunde quem clona pela primeira vez.** Pela pipeline, `enable_lambda_routes` é a variável de repositório `ENABLE_LAMBDA_ROUTES` ou o input do `workflow_dispatch`.

### Ordem entre repositórios

```
0. oficina-infra-k8s   base   (ECR + SSM — fica de pé sempre)
1. oficina-infra-k8s   cluster, 1º apply
2. oficina-infra-db    (RDS nas subnets privadas)
3. oficina-api         (imagem no ECR + Flyway aplica V6 e V7)
4. oficina-auth-lambda (funções + publica ARNs no SSM)
5. oficina-infra-k8s   cluster, 2º apply
```

Com a `base` de pé, o passo 3 funciona sem cluster: a imagem vai para o ECR e o deploy falha só no `kubectl`, que é esperado até o passo 1.

O passo 3 antes do 4 é obrigatório: a Lambda consulta `clientes.status`, coluna criada pela migration `V6`.

### Ordem do destroy

Workflow **Destroy AWS** em cada repositório, na ordem inversa:

```
1. oficina-auth-lambda  (ENIs da Lambda prendem subnet e security group)
2. oficina-infra-db     (RDS usa as subnets e referencia os SGs do cluster)
3. oficina-infra-k8s    stack=cluster
4. oficina-infra-k8s    stack=base      (opcional, centavos/mês)
5. bootstrap/bootstrap.sh destroy       (local, só no fim da fase)
```

O destroy do `cluster` falha logo no início se o RDS ou a stack da Lambda ainda existirem, e o da `base` falha se o EKS existir. Sem essa trava, o Terraform parava no meio com `DependencyViolation`.

## Contrato com os outros repositórios

Acoplamento único: **SSM Parameter Store** sob `/oficina/<ambiente>/`.

| Parâmetro | Direção |
|---|---|
| `vpc-id`, `private-subnet-ids`, `public-subnet-ids` | **publica** |
| `eks-cluster-name`, `eks-node-security-group-id` | **publica** |
| `lambda-security-group-id` | **publica** |
| `ecr-repository-url` | **publica** pela `base` |
| `nlb-dns` | **publica** |
| `api-gateway-id`, `api-gateway-url` | **publica** |
| `jwt-secret` (SecureString) | **publica** pela `base` — fonte única dos 3 consumidores |
| `db-endpoint`, `db-name`, `db-username`, `db-password` | consome de `oficina-infra-db` |
| `auth-lambda-arn`, `authorizer-lambda-arn` | consome de `oficina-auth-lambda` |

## Observabilidade

Dashboards e alertas em Terraform, como recomenda a Aula 10 — evita alteração não documentada e dá rastreabilidade.

**Dashboard "Oficina — Negócio"** traz os três painéis exigidos pelo enunciado: volume diário de OS, tempo médio por status e erros de integração. Nenhum deles sai do agente de APM; são métricas customizadas emitidas pela aplicação.

**Seis alert conditions**, nomeadas no padrão `AWS-OficinaAPI-<Ambiente>-<Recurso>-<Sintoma>-<Severidade>`. Cada uma carrega link para um runbook — a Aula 05 é categórica que alerta sem ação clara associada não é útil.

Ativar exige `enable_newrelic=true` e as chaves. Sem elas, o Terraform valida e aplica normalmente, só não cria os recursos de observabilidade.

## Custo

~US$ 0,20 por hora ligado. O **EKS control plane sozinho é US$ 73/mês** e não tem tier gratuito.

| Cenário | Custo |
|---|---|
| Sessão de trabalho de 4 h | US$ 0,79 |
| 10 sessões ao longo da fase | US$ 7,92 |
| Mês inteiro 24/7 | ~US$ 145 |

Estratégia: `terraform destroy` como estado padrão, subindo o ambiente para validar e gravar. O AWS Budget com alerta de previsão avisa antes de estourar.
