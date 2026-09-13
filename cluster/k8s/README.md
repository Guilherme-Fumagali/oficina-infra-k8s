# Kubernetes — oficina-api

Manifests para rodar a aplicação completa (API + Postgres + MailHog) em qualquer cluster Kubernetes.

## Pré-requisitos

- Um cluster Kubernetes acessível via `kubectl` — kind (`../infra/environments/local`), AWS EKS
  (`../infra/environments/aws`) ou qualquer outro.
- **metrics-server** — necessário para o HPA ler CPU/memória (sem ele o HPA fica `<unknown>` e não
  escala). Vendorizado como manifesto em [`metrics-server/`](metrics-server/) (upstream v0.7.2, sem
  modificações). Os dois ambientes Terraform já o aplicam.

  > **No kind** o kubelet serve certificado autoassinado, então o metrics-server precisa de
  > `--kubelet-insecure-tls` — o Terraform local aplica esse patch por cima do manifesto. No EKS
  > o certificado é assinado pela CA do cluster e o manifesto vale como está; por isso a flag
  > não entra no arquivo vendorizado.

## Segredos

Os arquivos `secret.yaml` (`app/` e `database/`) contêm apenas placeholders (`REPLACE_ME`). Antes de aplicar, gere os reais:

```
kubectl create namespace oficina --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic oficina-db-secret -n oficina \
  --from-literal=POSTGRES_USER=oficina \
  --from-literal=POSTGRES_PASSWORD=<senha-real> \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic oficina-api-secret -n oficina \
  --from-literal=DB_USER=oficina \
  --from-literal=DB_PASS=<senha-real> \
  --from-literal=JWT_SECRET=<chave-real-min-32-chars> \
  --from-literal=ADMIN_PASSWORD=<senha-real> \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Aplicar (ordem)

```
kubectl apply -f namespace.yaml
kubectl apply -f metrics-server/
kubectl apply -f database/
kubectl apply -f mailhog/
kubectl apply -f app/
```

> Os dois ambientes Terraform renderizam os `secret.yaml` a partir do tfvars, em vez de aplicar os
> placeholders versionados. No ambiente AWS o Terraform também substitui `app/configmap.yaml` pelo
> endpoint do RDS e pula `database/` (o banco é o RDS gerenciado, não in-cluster).

## Smoke test

```
kubectl get pods -n oficina -w        # aguardar Ready
kubectl port-forward svc/oficina-api 8080:80 -n oficina
curl http://localhost:8080/actuator/health
```

## Acompanhar o HPA

```
kubectl get hpa -n oficina -w
k6 run -e BASE_URL=http://localhost:8080 loadtest/k6-script.js
```

## Acesso

Sem Ingress configurado (fora de escopo por simplicidade) — use `kubectl port-forward` como acima. Um
`ingress-nginx` é um stretch opcional caso se queira uma URL fixa para a demo.
