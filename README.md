# oficina-infra-k8s

Plataforma compartilhada do sistema de gestão de oficina mecânica, desenvolvida no Tech Challenge da PosTech FIAP (Arquitetura de Software): rede, cluster Kubernetes, registry de imagens, borda HTTP e observabilidade dos três microsserviços.

| Repositório | Conteúdo |
|---|---|
| [tech-challenge-1](https://github.com/Guilherme-Fumagali/tech-challenge-1) | OS Service: cadastros, estoque, ordens de serviço e orquestração da saga |
| [oficina-billing-service](https://github.com/Guilherme-Fumagali/oficina-billing-service) | Billing Service: orçamento, aprovação e pagamento |
| [oficina-execution-service](https://github.com/Guilherme-Fumagali/oficina-execution-service) | Execution Service: fila de execução, diagnóstico e reparo |
| [oficina-auth-lambda](https://github.com/Guilherme-Fumagali/oficina-auth-lambda) | Autenticação por CPF com segundo fator |
| **oficina-infra-k8s** | Rede, EKS, ECR, API Gateway e New Relic (este repositório) |
| [oficina-infra-db](https://github.com/Guilherme-Fumagali/oficina-infra-db) | RDS da Fase 3, mantido como registro |

## Propósito

Provisiona com Terraform a infraestrutura comum entre a internet e os serviços: VPC com subnets privadas, cluster EKS com escalonamento, um repositório ECR por serviço, API Gateway com autenticação nas rotas protegidas, segredos compartilhados e os dashboards e alertas do New Relic.

Bancos, filas e identidades dos pods não são criados aqui. Cada serviço os declara no diretório `infra/` do próprio repositório e obtém VPC, subnets, security groups e segredos compartilhados pelo SSM Parameter Store.

## Mudanças da Fase 4

Na Fase 4 o monólito foi dividido em três serviços, e este repositório deixou de conter recursos de um serviço específico. As decisões estão registradas na [ADR-022](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/develop/docs/tech-challenge-4/adrs/ADR-022-infra-por-servico-pod-identity.md) (infraestrutura por serviço e Pod Identity) e na [ADR-023](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/develop/docs/tech-challenge-4/adrs/ADR-023-borda-por-servico.md) (borda com listener e NodePort por serviço).

| Tema | Fase 3 | Fase 4 |
|---|---|---|
| Borda | um listener no NLB e um target group no NodePort 30080 | um listener, um target group e uma integração `HTTP_PROXY` por serviço, declarados com `for_each` sobre `var.servicos` |
| Manifests da aplicação | gerados a partir do SSM e aplicados pelo `null_resource` deste repositório | mantidos em Kustomize no `k8s/` de cada serviço e aplicados pelo pipeline do serviço |
| Credenciais AWS dos pods | não havia | EKS Pod Identity: add-on `eks-pod-identity-agent` aqui; role e associação no `infra/` de cada serviço, limitadas pelo boundary `oficina-pod-boundary` |
| Registry | ECR `oficina-api-<ambiente>` | ECR `oficina-os-service-<ambiente>`, `oficina-billing-service-<ambiente>` e `oficina-execution-service-<ambiente>` |
| Segredos compartilhados | `jwt-secret` | `jwt-secret`, `chave-interna` (chamada da Lambda ao endpoint interno do OS) e `otp-segredo` (HMAC dos códigos do segundo fator) |
| Acesso dos pipelines ao cluster | uma role com edição no namespace `oficina` | lista com as três roles de pipeline dos serviços |
| Rede | gateway endpoint de S3 | gateway endpoints de S3 e de DynamoDB |
| Nós | tamanho do node group fixo no código | `node_desired_size`, `node_min_size` e `node_max_size` (padrão 2, 2 e 4) |
| Alertas | destino de e-mail criado sem workflow, sem envio de notificações | workflow ligando a política ao e-mail; condições por serviço, da saga e da mensageria |

Com os manifests da aplicação nos repositórios dos serviços, o DT-12 (manifests aplicados por `kubectl` dentro do Terraform) é fechado para os objetos da aplicação. O namespace `oficina`, o metrics-server, o MailHog e a integração Kubernetes do New Relic são compartilhados e continuam aplicados por `null_resource`, com o hash dos arquivos nos gatilhos.

## Arquitetura

```
                               Internet
                                   │
                    ┌──────────────▼──────────────┐
                    │    API Gateway HTTP API     │
                    └───┬─────────────────────┬───┘
   POST /auth e         │                     │  /api/... com Lambda authorizer
   confirmações         │                     │  (cache 300 s) e rotas públicas
                ┌───────▼───────┐      ┌──────▼──────┐
                │ Lambda        │      │  VPC Link   │
                │ (outro repo)  │      └──────┬──────┘
                └───────────────┘             │
  ┌───────────────────────────────────────────┼──────────────────────────┐
  │ VPC 10.0.0.0/16                           │                          │
  │                                           │                          │
  │  subnet pública 10.0.1.0/24 · 10.0.2.0/24                            │
  │     └── NAT instance t4g.nano (+EIP) ──────────────▶ internet        │
  │                                           │                          │
  │  subnet privada 10.0.11.0/24 · 10.0.12.0/24                          │
  │     ├── NLB interno ──────────────────────┘                          │
  │     │     ├── :80   ──▶ NodePort 30080 ──▶ os-service                │
  │     │     ├── :8081 ──▶ NodePort 30081 ──▶ billing-service           │
  │     │     └── :8082 ──▶ NodePort 30082 ──▶ execution-service         │
  │     ├── nós EKS t3.medium ×2, sem IP público                         │
  │     ├── Lambda de autenticação ──▶ NLB :80 (endpoint interno do OS)  │
  │     └── RDS e DocumentDB (repositórios dos serviços)                 │
  │                                                                      │
  │  gateway endpoints: S3 (camadas do ECR) e DynamoDB (desafios)        │
  └──────────────────────────────────────────────────────────────────────┘
                                   │
                      telemetria, SQS e SES pela NAT
                                   ▼
                      New Relic, Amazon SQS, Amazon SES
```

## Tecnologias

- Terraform 1.9.8, providers AWS ~> 5.70, Random ~> 3.6, New Relic ~> 3.48 e Null ~> 3.2
- Amazon EKS 1.36 com node group gerenciado, add-on EKS Pod Identity Agent e metrics-server para o HPA de cada serviço
- Amazon ECR com scan on push e lifecycle policy, um repositório por serviço
- API Gateway HTTP API, VPC Link e Network Load Balancer interno com um listener por serviço
- New Relic: workflow de notificação, condições de alerta, monitor sintético e dashboards declarados em Terraform
- Backend de state em S3 com lock em DynamoDB

## Recursos provisionados

| Grupo | Recursos |
|---|---|
| Rede | VPC, 2 subnets públicas, 2 privadas, internet gateway, NAT instance `t4g.nano`, route tables, gateway endpoints de S3 e DynamoDB, security group da Lambda |
| Cluster | EKS 1.36, node group `t3.medium` em subnet privada (2 nós por padrão, até 4), add-on `eks-pod-identity-agent`, IAM roles e access entries |
| Registry | 3 repositórios ECR, um por serviço, com retenção das 10 imagens mais recentes |
| Borda | HTTP API, VPC Link, NLB interno com 3 listeners e 3 target groups, Lambda authorizer, 4 rotas de autenticação com throttling e stage com access log |
| Kubernetes | namespace `oficina`, metrics-server, MailHog e integração Kubernetes do New Relic (chart `nri-bundle`) |
| Observabilidade | workflow de e-mail, 15 condições de alerta, monitor sintético e 3 dashboards |
| Orçamento | AWS Budget de US$ 50 com alerta de previsão |
| Integração | 16 parâmetros no SSM para os demais repositórios |

## Borda

O API Gateway encaminha as rotas dos serviços por VPC Link ao NLB interno. Cada serviço tem um listener próprio, que encaminha ao NodePort fixo do seu Service no cluster. O health check de cada target group consulta `/actuator/health/readiness` do serviço.

| Serviço | Listener do NLB | NodePort | Target group |
|---|---|---|---|
| OS Service | 80 | 30080 | `oficina-os-tg-<ambiente>` |
| Billing Service | 8081 | 30081 | `oficina-billing-tg-<ambiente>` |
| Execution Service | 8082 | 30082 | `oficina-execution-tg-<ambiente>` |

| Rota | Destino | Autorização |
|---|---|---|
| `ANY /api/{proxy+}` | OS | Lambda authorizer |
| `GET /api/ordens/{id}/status` | OS | pública |
| `GET /actuator/health` | OS | pública |
| `ANY /api/orcamentos`, `ANY /api/orcamentos/{proxy+}`, `ANY /api/pagamentos/{proxy+}` | Billing | Lambda authorizer |
| `GET /api/orcamentos/{id}/decisao`, `POST /api/orcamentos/{id}/decisao` | Billing | pública; o token de decisão é validado pelo serviço |
| `POST /api/pagamentos/webhooks/mercado-pago` | Billing | pública; a assinatura do Mercado Pago é validada pelo serviço |
| `ANY /api/execucoes`, `ANY /api/execucoes/{proxy+}` | Execution | Lambda authorizer |
| `POST /auth`, `POST /auth/confirmacao`, `POST /auth/funcionarios`, `POST /auth/funcionarios/confirmacao` | Lambda | pública; throttling de 10 req/s com rajada de 20 por rota |

O API Gateway seleciona a rota mais específica, de modo que as rotas públicas prevalecem sobre `{proxy+}` do mesmo prefixo, e `/api/orcamentos/{proxy+}` prevalece sobre `/api/{proxy+}`. As rotas `aprovar-externo` e `reprovar-externo` da Fase 3 foram removidas, pois a decisão sobre o orçamento passou para o Billing Service. O endpoint `/internal/identidades/*` do OS, consultado pela Lambda, não tem rota no gateway e só é alcançado pelo NLB, dentro da VPC.

As quatro rotas de autenticação estão no `depends_on` do stage, para que as configurações de throttling por rota sejam aplicadas depois da criação das rotas. Ingress controller e AWS Load Balancer Controller foram descartados: acrescentariam um componente ao cluster e permissões IAM sem ganho para três serviços com NodePort fixo.

## Ambientes

| | Homologação | Produção |
|---|---|---|
| Branch | `develop` | `main` |
| GitHub Environment | `staging`, sem aprovação | `prod`, com revisor |
| Recursos | `oficina-api-staging-*` e `oficina-*-service-staging`, VPC própria | `oficina-api-prod-*` e `oficina-*-service-prod`, VPC própria |
| State | `infra-k8s/staging/<stack>` | `infra-k8s/prod/<stack>` |
| Parâmetros no SSM | `/oficina/staging/…` | `/oficina/prod/…` |

Os ambientes não compartilham recursos, state, parâmetros ou segredos. A demonstração e os testes são realizados em homologação; produção tem o mesmo código e o mesmo pipeline, protegida por aprovação ([ADR-012](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/tech-challenge-3/adrs/ADR-012-ambientes-segregados.md)).

## Stacks

| Stack | Recursos | Custo | Aplicação |
|---|---|---|---|
| `base/` | ECR por serviço e parâmetros `<serviço>/ecr-repository-url`, `jwt-secret`, `chave-interna`, `otp-segredo` e `newrelic-license-key` | centavos por mês | automática no push em `develop`; com aprovação no push em `main` |
| `cluster/` | VPC, NAT, EKS, NLB, API Gateway, New Relic e manifests de plataforma | cerca de US$ 0,24 por hora | somente por `workflow_dispatch` na branch do ambiente |

A stack `base` permanece provisionada, pois os pipelines dos serviços publicam imagens no ECR. Os segredos `jwt-secret` (64 caracteres), `chave-interna` (48) e `otp-segredo` (64) são gerados pelo Terraform (`random_password`), com um valor por ambiente. A stack `cluster` é criada para testes e demonstrações e destruída em seguida.

## CI/CD e validação

Workflow [`terraform.yml`](.github/workflows/terraform.yml):

| Job | Quando executa | O que faz |
|---|---|---|
| Format & validate (base, cluster) | todo push, em qualquer branch | `terraform fmt -check`, `terraform validate`, tflint (regras recomendadas e ruleset AWS) e checkov nas duas stacks |
| Bootstrap do backend | `develop` e `main` | garante o bucket de state e a tabela de lock |
| Plan | `develop` e `main` | `terraform plan` da stack selecionada no ambiente da branch |
| Apply | `develop` e `main` | `terraform apply` no GitHub Environment do ambiente; em `main`, aguarda aprovação |

As roles com edição no namespace `oficina` vêm da variável `API_DEPLOY_ROLE_ARNS` do repositório, uma lista JSON com os ARNs das três roles de pipeline, repassada como `TF_VAR_ci_role_principal_arns`. Sem a variável, a lista é vazia e nenhuma access entry de pipeline é criada.

Workflow [`destroy-aws.yml`](.github/workflows/destroy-aws.yml): destrói a stack escolhida no ambiente da branch. A destruição do `cluster` não prossegue enquanto existirem a stack `oficina-auth-lambda-<ambiente>`, os RDS `oficina-os-db-<ambiente>` e `oficina-billing-db-<ambiente>`, o cluster DocumentDB `oficina-execution-docdb-<ambiente>` ou o RDS `oficina-api-db-<ambiente>` da Fase 3. Depois do destroy, o job falha se ainda houver EKS, NAT instance, NLB, instância RDS ou cluster DocumentDB do ambiente. A destruição da `base` não prossegue se o cluster existir.

As branches `develop` e `main` não aceitam push direto; o merge exige Pull Request com uma aprovação e os dois jobs **Format & validate** concluídos com sucesso. O plano não é salvo como artifact, pois o arquivo contém valores de variáveis sensíveis; o job de apply gera o plano novamente.

Alterações nas políticas IAM de `bootstrap/iam/` são validadas com o IAM Access Analyzer e com `aws iam simulate-principal-policy` antes de serem aplicadas.

### Análise estática

O checkov falha o job para qualquer verificação não listada em [`.checkov.yaml`](.checkov.yaml). As verificações suprimidas e o motivo:

| Verificação | Motivo |
|---|---|
| `CKV_AWS_51` | os pipelines publicam cada imagem com a tag do commit e com `latest`, sobrescrita a cada publicação |
| `CKV_AWS_136`, `CKV_AWS_337`, `CKV_AWS_158`, `CKV_AWS_58` | criptografia com chave gerenciada pela AWS; KMS dedicado tem custo mensal por chave |
| `CKV2_AWS_34` | parâmetros do tipo `String` guardam identificadores e URLs; segredos usam `SecureString` |
| `CKV_AWS_309` | rotas públicas por decisão: autenticação, consulta de status, health check, decisão sobre o orçamento por token e webhook do Mercado Pago |
| `CKV_AWS_339` | falso positivo: EKS 1.36 está em suporte padrão, mas não consta na lista da versão do checkov |
| `CKV_AWS_37`, `CKV2_AWS_11`, `CKV_AWS_91`, `CKV_AWS_126`, `CKV_AWS_338` | logs de control plane, flow logs, access logs do NLB, monitoramento detalhado e retenção de 1 ano têm custo e não são necessários em ambiente de estudo |
| `CKV_AWS_38`, `CKV_AWS_39` | endpoint público do EKS usado pelos pipelines, com autenticação por IAM e access entries |
| `CKV_AWS_130` | a NAT instance precisa de IP público na inicialização para instalar o iptables |
| `CKV2_AWS_41` | a NAT instance não chama APIs da AWS |
| `CKV_AWS_150` | o ambiente é destruído ao final de cada sessão |
| `CKV2_AWS_5`, `CKV2_AWS_15`, `CKV2_AWS_20` | falsos positivos: security groups usados pela Lambda e pelo VPC Link; ASG gerenciado pelo EKS; NLB TCP interno |

Foram corrigidos os apontamentos sem custo: disco da NAT instance criptografado, `ebs_optimized` e security group padrão da VPC sem regras. Os recursos acrescentados na Fase 4 (add-on de Pod Identity, gateway endpoint de DynamoDB, listeners, target groups, integrações e rotas por serviço) não geraram apontamentos novos no checkov 3.2.334 nem no tflint 0.55.0.

## Acesso dos pipelines à AWS

Nenhum repositório usa chave de acesso. Cada um assume uma role própria por OIDC, criada por `bootstrap/github-oidc.sh` com as políticas de `bootstrap/iam/` ([ADR-013](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/tech-challenge-3/adrs/ADR-013-identidade-das-pipelines.md)).

| Repositório | Role | Permissões |
|---|---|---|
| `tech-challenge-1` | `oficina-api-github-actions` | push no ECR `oficina-os-service-*`; state `os/*`; RDS `oficina-os-db-*` e seu security group; filas `oficina-*-os-eventos*`; parâmetros `/oficina/*/os/*`; leitura dos parâmetros compartilhados usados pelo serviço; role de pod `oficina-os-pod-*` com boundary e associação de Pod Identity; edição do namespace `oficina` |
| `oficina-billing-service` | `oficina-billing-service-github-actions` | o mesmo conjunto com o prefixo `billing`: ECR, state, RDS `oficina-billing-db-*`, filas `oficina-*-billing-comandos*`, parâmetros e role de pod |
| `oficina-execution-service` | `oficina-execution-service-github-actions` | o mesmo conjunto com o prefixo `execution`, com o cluster DocumentDB `oficina-execution-docdb-*` no lugar do RDS |
| `oficina-auth-lambda` | `oficina-auth-lambda-github-actions` | stack SAM, funções `oficina-auth*`, tabela DynamoDB `oficina-auth-*` e roles com o boundary `oficina-lambda-boundary` |
| `oficina-infra-db` | `oficina-infra-db-github-actions` | RDS `oficina-api-db-*` da Fase 3, security group e parâmetros `/oficina/*` |
| `oficina-infra-k8s` | `oficina-infra-k8s-github-actions` | rede, EKS e add-ons, NLB, API Gateway, ECR, budget e roles `oficina-api-eks-*` |

As roles criadas pelos pipelines recebem permissions boundary obrigatório. O `oficina-lambda-boundary` limita as funções a logs, interfaces de rede na VPC, leitura do SSM, itens das tabelas `oficina-auth-*` e `ses:SendEmail`; o remetente e os destinatários do SES são verificados uma vez na conta, fora de qualquer stack, e a política da função restringe o envio ao remetente configurado. O `oficina-pod-boundary` limita os pods ao envio, recebimento, exclusão e consulta de atributos das filas `oficina-*`. Um pipeline só cria role de pod com o prefixo do próprio serviço e com esse boundary, e só a repassa ao serviço `pods.eks.amazonaws.com`.

A trust policy aceita apenas tokens de `develop` e `main` e dos environments `staging` e `prod`, cada um restrito à sua branch. O script é executado manualmente por um administrador, fora do pipeline, e também define a variável `API_DEPLOY_ROLE_ARNS` deste repositório.

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

Os e-mails de orçamento enviados pelo Billing Service chegam ao MailHog do cluster. Para consultá-los:

```bash
kubectl port-forward -n oficina svc/oficina-mailhog 8025:8025
```

O diretório `local/` contém o ambiente kind da Fase 3, que implantava o monólito. Ele não foi adaptado aos três serviços, executados localmente pelo `docker-compose.yml` de cada repositório.

## Ordem de provisionamento

O gateway depende do ARN da Lambda, e a Lambda depende da rede criada aqui. A dependência é resolvida com dois applies do `cluster`, e os serviços entram entre eles:

```
1. bootstrap/bootstrap.sh create     backend de state (bucket e tabela de lock)
2. oficina-infra-k8s   base: ECR por serviço e parâmetros (permanece provisionada)
3. oficina-infra-k8s   cluster, apply 1: rede, EKS, Pod Identity, borda sem as rotas
                       da Lambda e manifests de plataforma
4. tech-challenge-1, oficina-billing-service, oficina-execution-service
                       infra/ de cada serviço: banco, filas e role de pod,
                       independentes entre si
5. oficina-auth-lambda funções, tabela de desafios e publicação dos ARNs no SSM
6. oficina-infra-k8s   cluster, apply 2: enable_lambda_routes
7. pipelines dos serviços: imagem, Secret a partir do SSM e deploy no namespace oficina
```

No apply 1, as rotas protegidas ainda não têm authorizer, que só é criado no apply 2. O namespace `oficina`, o metrics-server, o MailHog e a integração do New Relic são aplicados já no apply 1, pois não dependem dos bancos; os pipelines dos serviços têm permissão de edição apenas dentro do namespace e não podem criá-lo. Por isso o input `aplicar_manifests` da Fase 3 foi removido do workflow.

## Ordem de destruição

Workflow **Destroy AWS** de cada repositório, na branch do ambiente, na ordem inversa:

```
1. oficina-auth-lambda  as interfaces de rede da Lambda impedem a remoção de
                        subnets e security groups
2. tech-challenge-1, oficina-billing-service, oficina-execution-service
                        RDS e DocumentDB usam as subnets e referenciam o
                        security group do cluster
3. oficina-infra-k8s    stack=cluster
4. oficina-infra-k8s    stack=base      (opcional)
5. bootstrap/bootstrap.sh destroy       (local, ao final do projeto)
```

O passo 3 é recusado enquanto existirem a stack da Lambda ou os bancos dos serviços. O `bootstrap.sh destroy` confere, antes de apagar o bucket, que estão vazios os states `infra-k8s`, `infra-db`, `os`, `billing` e `execution` dos dois ambientes.

## Rede privada

Na Fase 2, os recursos estavam em subnets públicas. O material da Aula 04 de Serverless aponta o risco de banco de dados e APIs expostos publicamente, o que motivou a migração para subnets privadas.

Opções avaliadas para o acesso à internet, em `us-east-1` com duas zonas de disponibilidade:

| Opção | Cálculo | US$/mês |
|---|---|---|
| NAT Gateway | US$ 0,045/h | ~33 |
| VPC interface endpoints | US$ 0,01/h × 4 endpoints × 2 AZs | ~58 |
| NAT instance `t4g.nano` + EIP | US$ 0,0042/h + US$ 0,005/h | ~7 |

Os interface endpoints são cobrados por endpoint e por zona de disponibilidade e não atendem à telemetria do New Relic, enviada para um endpoint público. Foi escolhida a NAT instance ([ADR-007](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/tech-challenge-3/adrs/ADR-007-rede-privada-nat-instance.md)). Em subnet privada, os nós também deixam de usar IPv4 público, com economia de US$ 7,30 por mês.

Na Fase 4 foi acrescentado o gateway endpoint de DynamoDB, sem custo, associado à route table privada: a Lambda de autenticação, que roda na VPC, acessa a tabela de desafios do segundo fator sem passar pela NAT instance. As chamadas a SQS e SES continuam saindo pela NAT.

A NAT instance é um ponto único de falha em uma zona de disponibilidade. Em caso de falha, há perda de telemetria, de download de imagens, de troca de mensagens pelo SQS e de envio do código de acesso pelo SES. As consultas síncronas continuam respondendo, e as mensagens registradas no outbox de cada serviço são enviadas quando a saída é restabelecida (DT-04).

## Integração com os outros repositórios

A integração é feita pelo SSM Parameter Store, sob `/oficina/<ambiente>/`.

| Parâmetro | Direção |
|---|---|
| `vpc-id`, `private-subnet-ids`, `public-subnet-ids` | publicado |
| `eks-cluster-name`, `eks-node-security-group-id`, `lambda-security-group-id` | publicado |
| `os/ecr-repository-url`, `billing/ecr-repository-url`, `execution/ecr-repository-url` | publicado pela `base` |
| `jwt-secret`, `chave-interna`, `otp-segredo`, `newrelic-license-key` (SecureString) | publicado pela `base` |
| `nlb-dns`, `api-gateway-id`, `api-gateway-url` | publicado |
| `auth-lambda-arn`, `authorizer-lambda-arn` | consumido de `oficina-auth-lambda` |

Os parâmetros dos bancos (`/oficina/<ambiente>/<serviço>/db-*` e `docdb-*`) são publicados pelo `infra/` de cada serviço e lidos pelo pipeline do próprio serviço; esta stack deixou de consultá-los.

## Observabilidade

Dashboards, alertas e o workflow de notificação são declarados em Terraform, conforme recomendado na Aula 10. Cada serviço aparece no New Relic como uma aplicação própria: `oficina-os-service-<ambiente>`, `oficina-billing-service-<ambiente>` e `oficina-execution-service-<ambiente>`.

- **Dashboard da saga:** sagas iniciadas, concluídas, compensadas e em falha, compensações por motivo, etapas e duração por estado, mensagens publicadas e consumidas por tipo e resultado, mensagens nas DLQs, pagamentos por resultado, fila de execução por etapa e reenvios por comando. Não há métrica com o estado corrente de cada saga: o painel "Sagas por estado" conta as etapas concluídas em cada estado (`oficina.saga.etapa.duracao`), e o valor "Em andamento" é a diferença entre sagas iniciadas e encerradas nas últimas 24 horas.
- **Dashboard técnico:** latência p95, taxa de respostas 5xx e throughput facetados pelas três aplicações; pods disponíveis, CPU e memória dos pods das três deployments.
- **Dashboard de negócio:** ordens de serviço abertas por dia, tempo médio por status, orçamentos aprovados e reprovados, orçamentos gerados e valor aprovado.
- **Integração Kubernetes:** o chart `nri-bundle`, com a configuração de [`cluster/k8s/newrelic/values.yaml`](cluster/k8s/newrelic/values.yaml), é instalado por Helm no namespace `newrelic` junto com os manifests de plataforma e envia as métricas de nós, pods e deployments usadas no dashboard técnico e no alerta de memória.
- **Logs:** encaminhados pelo agente Java de cada serviço, com `trace.id` e `span.id` da transação, o que liga cada linha ao trace no APM. O Fluent Bit do chart fica desligado para não duplicar a ingestão.

Os alertas pertencem à política `AWS-Oficina-<Ambiente>`, e o workflow de mesmo nome envia os incidentes da política ao endereço da variável `ALERTA_EMAIL`. Na Fase 3 o destino de e-mail existia sem workflow, e nenhum incidente era notificado. Os nomes seguem o padrão `AWS-Oficina-<Ambiente>-<Recurso>-<Sintoma>-<Severidade>`, e cada condição aponta, em `runbook_url`, para um arquivo de [`tech-challenge-1/docs/runbooks`](https://github.com/Guilherme-Fumagali/tech-challenge-1/tree/main/docs/runbooks).

| Condição | Sinal | Limite | Runbook |
|---|---|---|---|
| `<Serviço>-LatenciaP95-Warning`, uma por serviço | p95 das transações web | acima de 1 s por 10 min | `api-latencia-alta.md` |
| `<Serviço>-TaxaErro5xx-Critical`, uma por serviço | percentual de respostas 5xx | acima de 2% por 5 min | `api-taxa-erro.md` |
| `<Serviço>-MemoriaPod-Warning`, uma por serviço | memória de trabalho do container em relação ao limite | acima de 85% por 10 min | `k8s-memoria-pod.md` |
| `Mensageria-DLQ-Critical` | `max(oficina.mensageria.dlq.mensagens)` por fila | acima de 0 | `mensageria-dlq.md` |
| `Saga-Falha-Critical` | `sum(oficina.saga.falhas)` | acima de 0 | `saga-falha.md` |
| `Saga-Compensacoes-Warning` | `sum(oficina.saga.compensadas)` | acima de 5 em 15 min | `saga-compensacoes.md` |
| `MercadoPago-Falhas-Warning` | `sum(oficina.integracao.mercadopago)` com `resultado` diferente de `sucesso` | acima de 0 em 5 min | `mercadopago-falhas.md` |
| `OS-FalhaTransicao-Critical` | `sum(oficina.os.transicoes)` com `resultado = 'falha'` | acima de 5 por 5 min | `os-falha-transicao.md` |
| `Health-Uptime-Critical` | falhas do monitor sintético em `/actuator/health` | 2 ou mais por 10 min | `health-uptime.md` |

`<Serviço>` assume os valores `OsService`, `BillingService` e `ExecutionService`. As condições de memória filtram o cluster do ambiente, o namespace `oficina` e o nome da deployment.

A criação exige `ENABLE_NEWRELIC=true` e as credenciais do New Relic. Sem elas, o Terraform aplica os demais recursos normalmente.

## Custo

Com a stack `cluster` provisionada, o custo continua em cerca de US$ 0,24 por hora; o control plane do EKS custa US$ 73 por mês e não tem nível gratuito. Os listeners e target groups adicionais, o VPC Link, o gateway endpoint de DynamoDB e o add-on de Pod Identity não têm cobrança própria. O terceiro nó, habilitado com `node_desired_size = 3`, acrescenta cerca de US$ 0,04 por hora (`t3.medium` sob demanda em `us-east-1`). Na stack `base`, o ECR passa a ter três repositórios, cobrados por armazenamento (US$ 0,10 por GB-mês) e limitados às 10 imagens mais recentes cada.

| Cenário | Custo da stack `cluster` |
|---|---|
| Sessão de trabalho de 4 h | US$ 0,96 |
| 10 sessões ao longo da fase | US$ 9,58 |
| Mês completo em operação contínua | ~US$ 175 |

Os bancos são provisionados nos repositórios dos serviços: dois RDS PostgreSQL `db.t4g.micro` e um DocumentDB `db.t4g.medium`. Com eles, a estimativa do ambiente completo é de cerca de US$ 0,33 por hora, ou US$ 1,35 por sessão de 4 h. O ambiente é destruído ao final de cada sessão, e o AWS Budget emite alerta com base na previsão de gasto.
