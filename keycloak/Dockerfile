# Imagem própria do Keycloak com o realm já embutido no build, em vez de um bind
# mount em tempo de execução (./k8s/keycloak:/opt/keycloak/data/import). O bind mount
# vindo de um path WSL (\\wsl.localhost\...) falha intermitentemente no Docker Desktop
# com "accessing specified distro mount service" — copiar o arquivo no build evita
# essa ponte por completo.
FROM quay.io/keycloak/keycloak:26.5
COPY k8s/keycloak/realm-export.json /opt/keycloak/data/import/realm-export.json
