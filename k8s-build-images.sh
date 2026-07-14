#!/usr/bin/env bash
# Builda as 4 imagens dos microsserviços direto no Docker interno do Minikube,
# usando os Dockerfiles que já existem em cada repositório irmão (../FIAP.*).
# Rodar de dentro do WSL: wsl.exe -d debian -e bash -lc "cd /caminho/FIAP.Orchestration && ./k8s-build-images.sh"
set -euo pipefail

eval "$(minikube docker-env)"

cd "$(dirname "$0")/.."

echo "=== catalog-api ==="
docker build -t fiap/catalog-api:latest ./FIAP.CatalogAPI

echo "=== usuarios-api ==="
docker build -t fiap/usuarios-api:latest ./FIAP.UsersAPI

echo "=== payment-api ==="
docker build -t fiap/payment-api:latest ./FIAP.PaymentAPI

echo "=== notifications-api ==="
docker build -t fiap/notifications-api:latest ./FIAP.NotificationsAPI

echo ""
echo "4 imagens buildadas. Agora aplique os manifestos com:"
echo "  kubectl apply -k k8s/"
