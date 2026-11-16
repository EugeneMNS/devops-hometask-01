#!/usr/bin/env bash
# Run on the VPS with sudo. Existing nginx and Docker workloads stay running.
set -euo pipefail

if [[ "$EUID" -ne 0 || "${SUDO_USER:-root}" == root ]]; then
  echo 'Run as the deploy user: sudo bash scripts/bootstrap-k3s.sh' >&2
  exit 1
fi

server_ip="${1:-57.131.194.112}"
k3s_version='v1.35.10+k3s1'
deploy_user="$SUDO_USER"
deploy_home="$(getent passwd "$deploy_user" | cut -d: -f6)"
test -n "$deploy_home"

if command -v k3s >/dev/null 2>&1; then
  echo 'k3s is already installed; inspect its configuration before rerunning.' >&2
  exit 1
fi

installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT
curl --fail --silent --show-error --location https://get.k3s.io -o "$installer"
INSTALL_K3S_VERSION="$k3s_version" sh "$installer" server \
  --disable=traefik --tls-san "$server_ip"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 6443/tcp
  ufw allow from 10.42.0.0/16 to any
  ufw allow from 10.43.0.0/16 to any
fi

install -d -m 700 -o "$deploy_user" -g "$(id -gn "$deploy_user")" "$deploy_home/.kube"
if [[ -e "$deploy_home/.kube/config" ]]; then
  cp -p "$deploy_home/.kube/config" "$deploy_home/.kube/config.before-hw6"
fi
install -m 600 -o "$deploy_user" -g "$(id -gn "$deploy_user")" \
  /etc/rancher/k3s/k3s.yaml "$deploy_home/.kube/config"

k3s kubectl wait --for=condition=Ready nodes --all --timeout=180s
k3s kubectl get nodes
echo 'k3s is ready. Existing web routes are still served by system nginx.'
