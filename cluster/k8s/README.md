# Manifests Kubernetes da plataforma

Objetos compartilhados pelos três serviços, aplicados pela stack `cluster` a cada apply em que o cluster ou os arquivos mudam:

| Caminho | Conteúdo |
|---|---|
| `namespace.yaml` | namespace `oficina`, no qual os pipelines dos serviços implantam |
| `metrics-server/` | metrics-server v0.7.2 (upstream, sem modificações), necessário para o HPA de cada serviço |
| `mailhog/` | servidor SMTP de teste que recebe os e-mails de orçamento do Billing Service |
| `newrelic/values.yaml` | valores do chart `nri-bundle` (integração Kubernetes do New Relic), instalado por Helm no namespace `newrelic` quando `enable_newrelic = true` |

Deployment, Service, HPA, PDB, ServiceAccount, ConfigMap e Secret de cada serviço ficam no diretório `k8s/` do repositório do serviço, em Kustomize, e são aplicados pelo pipeline desse serviço. Os NodePorts fixos 30080, 30081 e 30082 formam o contrato com os target groups do NLB declarados em [`../apigateway.tf`](../apigateway.tf).

Os diretórios `database/` e `loadtest/` não são aplicados pelo Terraform. `database/` contém o PostgreSQL em StatefulSet do ambiente kind de [`../../local`](../../local), e `loadtest/` contém o script do k6.

## Aplicação manual

Em um cluster sem a stack `cluster`:

```
kubectl apply -f namespace.yaml
kubectl apply -f metrics-server/
kubectl apply -f mailhog/
```

No kind, o metrics-server precisa da flag `--kubelet-insecure-tls`, pois o kubelet usa certificado autoassinado ([`../../local/metrics-server-kind-patch.json`](../../local/metrics-server-kind-patch.json)). No EKS, o certificado é assinado pela CA do cluster e a flag não é necessária.

## Teste de carga e HPA

O k6 roda em um pod no próprio cluster, para que a carga chegue aos pods sem passar pelo throttling do API Gateway. O alvo padrão é o Service `os-service`. Com `TOKEN`, cada iteração consulta `GET /api/ordens`, que acessa o banco; sem token, consulta `/actuator/health`.

```
kubectl get hpa -n oficina -w

kubectl run k6 -i --rm --restart=Never -n oficina --image=grafana/k6:0.57.0 \
  -- run -e TOKEN="$TOKEN" - < loadtest/k6-script.js
```

O perfil sobe para 30 usuários virtuais em 1 minuto, mantém por 3 minutos e desce em 1 minuto.

## Acesso

No EKS, o acesso externo é feito pelo API Gateway, por VPC Link e NLB interno, com um listener por serviço. Os e-mails recebidos pelo MailHog são consultados com:

```
kubectl port-forward -n oficina svc/oficina-mailhog 8025:8025
```
