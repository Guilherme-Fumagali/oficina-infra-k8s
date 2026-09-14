# oficina-infra-k8s

Infraestrutura de rede, cluster Kubernetes, registry de imagens, API Gateway e observabilidade do sistema de gestão de oficina mecânica, desenvolvida no Tech Challenge da PosTech FIAP (Arquitetura de Software).

| Repositório | Conteúdo |
|---|---|
| [tech-challenge-1](https://github.com/Guilherme-Fumagali/tech-challenge-1) | Aplicação oficina-api |
| [oficina-auth-lambda](https://github.com/Guilherme-Fumagali/oficina-auth-lambda) | Autenticação por CPF |
| **oficina-infra-k8s** | Rede, EKS, ECR, API Gateway e New Relic (este repositório) |
| [oficina-infra-db](https://github.com/Guilherme-Fumagali/oficina-infra-db) | RDS PostgreSQL |

## Propósito

Provisiona com Terraform a infraestrutura entre a internet e a aplicação: VPC com subnets privadas, cluster EKS com escalonamento, ECR, API Gateway com autenticação nas rotas protegidas e dashboards e alertas do New Relic.

Este repositório é responsável pela rede. Os demais repositórios obtêm VPC, subnets e security groups pelo SSM Parameter Store.

## Arquitetura

```
                            Internet
                                │
                    ┌───────────▼────────────┐
                    │   API Gateway HTTP API │
                    └──┬──────────────────┬──┘
  POST /auth e         │                  │  ANY /api/{proxy+}
  /auth/funcionarios   │                  │  (Lambda authorizer, cache 300s)
              ┌────────▼──────┐    ┌──────▼────────┐
              │ Lambda        │    │  VPC Link     │
              │ (outro repo)  │    └──────┬────────┘
              └───────────────┘           │
   ┌──────────────────────────────────────┼─────────────────────────────┐
   │ VPC 10.0.0.0/16                      │                             │
   │                                      │                             │
   │  subnet pública 10.0.1.0/24 · 10.0.2.0/24                          │
   │     └── NAT instance t4g.nano (+EIP) ──────────▶ internet          │
   │                                      │                             │
   │  subnet privada 10.0.11.0/24 · 10.0.12.0/24                        │
   │     ├── NLB interno ─────────────────┘                             │
   │     │      └──▶ NodePort 30080 ──▶ EKS ──▶ oficina-api (HPA 2–4)   │
   │     ├── nós EKS (t3.small ×2, sem IP público)                      │
   │     └── RDS (repositório oficina-infra-db)                         │
   │                                                                    │
   │  S3 gateway endpoint ──▶ camadas de imagem do ECR                  │
   └────────────────────────────────────────────────────────────────────┘
                                  │
                       telemetria pela NAT
                                  ▼
                             New Relic
```

## Tecnologias

- Terraform 1.9.8, providers AWS ~> 5.70 e New Relic ~> 3.48
- Amazon EKS 1.36 com node group gerenciado e HPA por CPU e memória
- Amazon ECR com scan on push e lifecycle policy
- API Gateway HTTP API, VPC Link e Network Load Balancer interno
- New Relic: dashboards, condições de alerta e monitor sintético declarados em Terraform
- Backend de state em S3 com lock em DynamoDB

## Recursos provisionados

| Grupo | Recursos |
|---|---|
| Rede | VPC, 2 subnets públicas, 2 privadas, internet gateway, NAT instance `t4g.nano`, route tables, S3 gateway endpoint, security group da Lambda |
| Cluster | EKS 1.36, node group `t3.small` ×2 (máximo 4) em subnet privada, IAM roles e access entries |
| Registry | ECR `oficina-api-<ambiente>` com retenção das 10 imagens mais recentes |
| Borda | HTTP API, VPC Link, NLB interno, target group no NodePort 30080, Lambda authorizer, rotas `POST /auth` e `POST /auth/funcionarios` com throttling de 10 req/s e stage com access log |
| Observabilidade | 6 condições de alerta, monitor sintético e 2 dashboards |
| Orçamento | AWS Budget de US$ 50 com alerta de previsão |
| Integração | 12 parâmetros no SSM para os demais repositórios |

## Ambientes

| | Homologação | Produção |
|---|---|---|
| Branch | `develop` | `main` |
| GitHub Environment | `staging`, sem aprovação | `prod`, com revisor |
| Recursos | `oficina-api-staging-*`, VPC própria | `oficina-api-prod-*`, VPC própria |
| State | `infra-k8s/staging/<stack>` | `infra-k8s/prod/<stack>` |
| Parâmetros no SSM | `/oficina/staging/…` | `/oficina/prod/…` |

Os ambientes não compartilham recursos, state, parâmetros ou segredos. A demonstração e os testes são realizados em homologação; produção tem o mesmo código e o mesmo pipeline, protegida por aprovação ([ADR-012](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/tech-challenge-3/adrs/ADR-012-ambientes-segregados.md)).

## Stacks

| Stack | Recursos | Custo | Aplicação |
|---|---|---|---|
| `base/` | ECR e parâmetros `ecr-repository-url`, `jwt-secret` e `newrelic-license-key` | centavos por mês | automática no push em `develop`; com aprovação no push em `main` |
| `cluster/` | VPC, NAT, EKS, NLB, API Gateway, New Relic e manifests | cerca de US$ 0,20 por hora | somente por `workflow_dispatch` na branch do ambiente |

A stack `base` permanece provisionada, pois o pipeline da aplicação publica imagens no ECR. A stack `cluster` é criada para testes e demonstrações e destruída em seguida. O `jwt-secret` é gerado pelo Terraform (`random_password`), com um valor por ambiente.

## CI/CD e validação

Workflow [`terraform.yml`](.github/workflows/terraform.yml):

| Job | Quando executa | O que faz |
|---|---|---|
| Format & validate (base, cluster) | todo push, em qualquer branch | `terraform fmt -check`, `terraform validate`, tflint (regras recomendadas e ruleset AWS) e checkov nas duas stacks |
| Bootstrap do backend | `develop` e `main` | garante o bucket de state e a tabela de lock |
| Plan | `develop` e `main` | `terraform plan` da stack selecionada no ambiente da branch |
| Apply | `develop` e `main` | `terraform apply` no GitHub Environment do ambiente; em `main`, aguarda aprovação |

Workflow [`destroy-aws.yml`](.github/workflows/destroy-aws.yml): destrói a stack escolhida no ambiente da branch. A destruição do `cluster` não prossegue se o RDS ou a Lambda do ambiente existirem, e a da `base` não prossegue se o cluster existir.

As branches `develop` e `main` não aceitam push direto; o merge exige Pull Request com uma aprovação e os dois jobs **Format & validate** concluídos com sucesso. O plano não é salvo como artifact, pois o arquivo contém valores de variáveis sensíveis; o job de apply gera o plano novamente.

Alterações nas políticas IAM de `bootstrap/iam/` são validadas com o IAM Access Analyzer e com `aws iam simulate-principal-policy` antes de serem aplicadas.

### Análise estática

O checkov falha o job para qualquer verificação não listada em [`.checkov.yaml`](.checkov.yaml). As verificações suprimidas e o motivo:

| Verificação | Motivo |
|---|---|
| `CKV_AWS_51` | imagens publicadas também com a tag `latest`, usada no primeiro apply dos manifests |
| `CKV_AWS_136`, `CKV_AWS_337`, `CKV_AWS_158`, `CKV_AWS_58` | criptografia com chave gerenciada pela AWS; KMS dedicado tem custo mensal por chave |
| `CKV2_AWS_34` | parâmetros do tipo `String` guardam identificadores e URLs; segredos usam `SecureString` |
| `CKV_AWS_309` | rotas públicas por decisão: autenticação, consulta de status e aprovação externa por token |
| `CKV_AWS_339` | falso positivo: EKS 1.36 está em suporte padrão, mas não consta na lista da versão do checkov |
| `CKV_AWS_37`, `CKV2_AWS_11`, `CKV_AWS_91`, `CKV_AWS_126`, `CKV_AWS_338` | logs de control plane, flow logs, access logs do NLB, monitoramento detalhado e retenção de 1 ano têm custo e não são necessários em ambiente de estudo |
| `CKV_AWS_38`, `CKV_AWS_39` | endpoint público do EKS usado pelo pipeline, com autenticação por IAM e access entries |
| `CKV_AWS_130` | a NAT instance precisa de IP público na inicialização para instalar o iptables |
| `CKV2_AWS_41` | a NAT instance não chama APIs da AWS |
| `CKV_AWS_150` | o ambiente é destruído ao final de cada sessão |
| `CKV2_AWS_5`, `CKV2_AWS_15`, `CKV2_AWS_20` | falsos positivos: security groups usados pela Lambda e pelo VPC Link; ASG gerenciado pelo EKS; NLB TCP interno |

Foram corrigidos os apontamentos sem custo: disco da NAT instance criptografado, `ebs_optimized` e security group padrão da VPC sem regras.

## Acesso dos pipelines à AWS

Nenhum repositório usa chave de acesso. Cada um assume uma role própria por OIDC, criada por `bootstrap/github-oidc.sh` com as políticas de `bootstrap/iam/` ([ADR-013](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/tech-challenge-3/adrs/ADR-013-identidade-das-pipelines.md)).

| Repositório | Role | Permissões |
|---|---|---|
| `tech-challenge-1` | `oficina-api-github-actions` | push nos ECR `oficina-api-*`, leitura de 2 parâmetros do SSM e edição do namespace `oficina` |
| `oficina-auth-lambda` | `oficina-auth-lambda-github-actions` | stack SAM, funções `oficina-auth*` e roles com o boundary `oficina-lambda-boundary` |
| `oficina-infra-db` | `oficina-infra-db-github-actions` | RDS `oficina-api-db-*`, security group e parâmetros `/oficina/*` |
| `oficina-infra-k8s` | `oficina-infra-k8s-github-actions` | rede, EKS, NLB, API Gateway, ECR, budget e roles `oficina-api-eks-*` |

A trust policy aceita apenas tokens de `develop` e `main` e dos environments `staging` e `prod`, cada um restrito à sua branch. O script é executado manualmente por um administrador, fora do pipeline.

## Execução

Pelo pipeline, na branch do ambiente:

```bash
gh workflow run terraform.yml --repo Guilherme-Fumagali/oficina-infra-k8s --ref develop -f stack=cluster
```

Localmente, com credenciais AWS e Terraform 1.9.8:

```bash
cd base
terraform init -backend-config="key=infra-k8s/staging/base/terraform.tfstate"
terraform apply -var="ambiente=staging"

cd ../cluster
terraform init -backend-config="key=infra-k8s/staging/cluster/terraform.tfstate"
terraform apply -var="ambiente=staging"
```

Validação sem credenciais, em cada stack:

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
```

O diretório `local/` provisiona um cluster kind com os mesmos manifests, para execução sem custo.

Os e-mails de orçamento são enviados ao MailHog do cluster. Para consultá-los:

```bash
kubectl port-forward -n oficina svc/oficina-mailhog 8025:8025
```

## Ordem de provisionamento

O gateway depende do ARN da Lambda, e a Lambda depende da rede criada aqui. A dependência é resolvida com dois applies do `cluster`:

```
0. oficina-infra-k8s   base: ECR e parâmetros (permanece provisionada)
1. oficina-infra-k8s   cluster, apply 1: rede, EKS e gateway sem as rotas da Lambda
2. oficina-infra-db    RDS nas subnets privadas
3. oficina-auth-lambda funções e publicação dos ARNs no SSM
4. oficina-infra-k8s   cluster, apply 2: enable_lambda_routes e aplicar_manifests
```

No passo 4, os manifests da aplicação e do MailHog são aplicados, os pods são iniciados e o Flyway executa as migrations. Em homologação, a migration `V9` cadastra o funcionário cujo CPF está no secret `FUNCIONARIO_SEED_CPF`. Os manifests dependem do endereço do banco, por isso não podem ser aplicados no passo 1. `enable_lambda_routes` e `aplicar_manifests` são inputs do `workflow_dispatch`.

## Ordem de destruição

Workflow **Destroy AWS** de cada repositório, na branch do ambiente, na ordem inversa:

```
1. oficina-auth-lambda  (as interfaces de rede da Lambda impedem a remoção de subnets e security groups)
2. oficina-infra-db     (o RDS usa as subnets e referencia os security groups do cluster)
3. oficina-infra-k8s    stack=cluster
4. oficina-infra-k8s    stack=base      (opcional)
5. bootstrap/bootstrap.sh destroy       (local, ao final do projeto)
```

## Rede privada

Na Fase 2, os recursos estavam em subnets públicas. O material da Aula 04 de Serverless aponta o risco de banco de dados e APIs expostos publicamente, o que motivou a migração para subnets privadas.

Opções avaliadas para o acesso à internet, em `us-east-1` com duas zonas de disponibilidade:

| Opção | Cálculo | US$/mês |
|---|---|---|
| NAT Gateway | US$ 0,045/h | ~33 |
| VPC interface endpoints | US$ 0,01/h × 4 endpoints × 2 AZs | ~58 |
| NAT instance `t4g.nano` + EIP | US$ 0,0042/h + US$ 0,005/h | ~7 |

Os interface endpoints são cobrados por endpoint e por zona de disponibilidade e não atendem à telemetria do New Relic, enviada para um endpoint público. Foi escolhida a NAT instance ([ADR-007](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/tech-challenge-3/adrs/ADR-007-rede-privada-nat-instance.md)). Em subnet privada, os nós também deixam de usar IPv4 público, com economia de US$ 7,30 por mês.

A NAT instance é um ponto único de falha em uma zona de disponibilidade. Em caso de falha, há perda de telemetria e de download de imagens, sem indisponibilidade da API (DT-04).

## Integração com os outros repositórios

A integração é feita pelo SSM Parameter Store, sob `/oficina/<ambiente>/`.

| Parâmetro | Direção |
|---|---|
| `vpc-id`, `private-subnet-ids`, `public-subnet-ids` | publicado |
| `eks-cluster-name`, `eks-node-security-group-id`, `lambda-security-group-id` | publicado |
| `ecr-repository-url`, `jwt-secret` (SecureString) | publicado pela `base` |
| `nlb-dns`, `api-gateway-id`, `api-gateway-url` | publicado |
| `db-endpoint`, `db-name`, `db-username`, `db-password` | consumido de `oficina-infra-db` |
| `auth-lambda-arn`, `authorizer-lambda-arn` | consumido de `oficina-auth-lambda` |

## Observabilidade

Dashboards e alertas são declarados em Terraform, conforme recomendado na Aula 10.

- **Dashboard de negócio:** volume diário de ordens de serviço, tempo médio por status e erros de integração, a partir de métricas customizadas da aplicação.
- **Dashboard técnico:** latência por percentil, taxa de erros, recursos por pod, réplicas do HPA e Apdex.
- **Alertas:** seis condições no padrão `AWS-OficinaAPI-<Ambiente>-<Recurso>-<Sintoma>-<Severidade>`, cada uma com link para o runbook correspondente em `tech-challenge-1/docs/runbooks`.

A criação exige `ENABLE_NEWRELIC=true` e as credenciais do New Relic. Sem elas, o Terraform aplica os demais recursos normalmente.

## Custo

Com a stack `cluster` provisionada, o custo é de cerca de US$ 0,20 por hora; o control plane do EKS custa US$ 73 por mês e não tem nível gratuito.

| Cenário | Custo |
|---|---|
| Sessão de trabalho de 4 h | US$ 0,79 |
| 10 sessões ao longo da fase | US$ 7,92 |
| Mês completo em operação contínua | ~US$ 145 |

O ambiente é destruído ao final de cada sessão. O AWS Budget emite alerta com base na previsão de gasto.
