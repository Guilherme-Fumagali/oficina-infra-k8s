# Manifests Kubernetes — oficina-api

Manifests da aplicação (API, PostgreSQL e MailHog) para qualquer cluster Kubernetes.

No EKS, a stack `cluster` aplica esses manifests quando executada com `aplicar_manifests=true`: o ConfigMap e o Secret são gerados a partir do SSM, o banco é o RDS e o diretório `database/` não é aplicado. No ambiente local com kind (`../../local`), o Terraform também aplica os manifests.

## Pré-requisitos

- Cluster acessível por `kubectl` (kind, EKS ou outro).
- metrics-server, necessário para o HPA ler CPU e memória. O manifesto está em [`metrics-server/`](metrics-server/) (versão upstream v0.7.2, sem modificações). No kind, o Terraform local acrescenta `--kubelet-insecure-tls`, pois o kubelet usa certificado autoassinado; no EKS, o certificado é assinado pela CA do cluster e a flag não é necessária.

## Segredos

Os arquivos `secret.yaml` de `app/` e `database/` contêm apenas placeholders (`REPLACE_ME`). Para aplicação manual, crie os valores reais:

```
kubectl create namespace oficina --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic oficina-db-secret -n oficina \
  --from-literal=POSTGRES_USER=oficina \
  --from-literal=POSTGRES_PASSWORD=<senha> \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic oficina-api-secret -n oficina \
  --from-literal=DB_USER=oficina \
  --from-literal=DB_PASS=<senha> \
  --from-literal=JWT_SECRET=<chave-com-pelo-menos-32-caracteres> \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Ordem de aplicação

```
kubectl apply -f namespace.yaml
kubectl apply -f metrics-server/
kubectl apply -f database/
kubectl apply -f mailhog/
kubectl apply -f app/
```

## Verificação

```
kubectl get pods -n oficina -w
kubectl port-forward svc/oficina-api 8080:80 -n oficina
curl http://localhost:8080/actuator/health
```

## Teste de carga e HPA

O k6 roda em um pod no próprio cluster, para que a carga chegue aos pods sem passar pelo throttling do API Gateway. Com `TOKEN`, cada iteração consulta `GET /api/ordens`, que acessa o banco; sem token, consulta `/actuator/health`.

```
kubectl get hpa -n oficina -w

kubectl run k6 -i --rm --restart=Never -n oficina --image=grafana/k6:0.57.0 \
  -- run -e TOKEN="$TOKEN" - < loadtest/k6-script.js
```

O perfil sobe para 30 usuários virtuais em 1 minuto, mantém por 3 minutos e desce em 1 minuto.

## Acesso

No EKS, o acesso externo é feito pelo API Gateway, por VPC Link e NLB interno. Em clusters sem gateway, como o kind, o acesso é feito com `kubectl port-forward`.
