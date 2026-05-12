#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — Create / update / recreate a local kind Kubernetes cluster with:
#   - Istio service mesh + ingress gateway (host ports 80/443)
#     handles both Kubernetes Gateway API (HTTPRoute) and classic Ingress resources
#     (set ingressClassName: istio on Ingress objects)
#   - cert-manager with a self-signed ClusterIssuer
#   - local-path-provisioner for persistent host storage
#   - DNS wildcard *.localhost.localdomain → 127.0.0.1
#     macOS:  Homebrew dnsmasq + /etc/resolver/localhost.localdomain
#   - local Docker registry  (localhost:5001, accessible as kind-registry:5000)
#
# Configuration: edit .env (all options documented there).
#
# Usage:
#   ./setup.sh                            — create cluster (skip if exists) + install/upgrade all components
#   ./setup.sh --recreate --clean-storage — delete cluster and recreate it from scratch (keeps host storage)
#
# Optional flags (combine with --recreate):
#   --clean-storage        — also wipe ${STORAGE_ROOT} for a full clean slate
#
# Feature toggles (set in .env):
#   ENABLE_INGRESS=true    — install cert-manager + Gateway API + Istio + IngressClass + wildcard TLS + ServiceMonitor CRD
#   ENABLE_REGISTRY=true   — start local kind-registry + Docker Hub mirrors + containerd no-proxy + localhost:5001 redirect
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults (overridden by .env) ──────────────────────────────────────────────
CLUSTER_NAME="local-dev"
LOCAL_REGISTRY_NAME="kind-registry"
LOCAL_REGISTRY_PORT="5001"
ISTIO_VERSION="1.23.3"
GATEWAY_API_VERSION="v1.2.1"
CERT_MANAGER_VERSION="v1.16.2"
STORAGE_ROOT="/var/local-path-provisioner"
K8S_VERSION="v1.35.0"
ISTIO_HTTP_PORT=80
ISTIO_HTTPS_PORT=443
ISTIO_NODEPORT_HTTP=30080
ISTIO_NODEPORT_HTTPS=30443
MIRRORS=(
  "https://dockerhub.timeweb.cloud"
  "https://dockerhub1.beget.com"
  "https://mirror.gcr.io"
)

# Optional feature toggles — set to "false" in .env to skip the corresponding block
ENABLE_INGRESS=true   # cert-manager + Gateway API + Istio + IngressClass + wildcard TLS + ServiceMonitor CRD + DNS check
ENABLE_REGISTRY=true  # local kind-registry container + KEP-1755 ConfigMap + Docker Hub mirrors + containerd no-proxy

# ── Load .env (overrides defaults above) ──────────────────────────────────────
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"

# ── Require macOS ─────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || die "This script requires macOS."

# ── Generate kind cluster config from kind-config.yaml + .env variables ────────
mkdir -p "${SCRIPT_DIR}/.cache"
KIND_CONFIG="${SCRIPT_DIR}/.cache/kind-config.yaml"
export CLUSTER_NAME K8S_VERSION \
       ISTIO_HTTP_PORT ISTIO_HTTPS_PORT ISTIO_NODEPORT_HTTP ISTIO_NODEPORT_HTTPS \
       STORAGE_ROOT
envsubst < "${SCRIPT_DIR}/kind-config.yaml" > "${KIND_CONFIG}"

RECREATE=false
CLEAN_STORAGE=false
for arg in "$@"; do
  case "$arg" in
    --recreate)       RECREATE=true ;;
    --clean-storage)  CLEAN_STORAGE=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

if [[ "${CLEAN_STORAGE}" == "true" && "${RECREATE}" == "false" ]]; then
  die "--clean-storage requires --recreate"
fi

# ── helpers ────────────────────────────────────────────────────────────────

log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ! $*\033[0m"; }
die()  { echo -e "\033[1;31m  ✗ $*\033[0m" >&2; exit 1; }

require() {
  command -v "$1" &>/dev/null || die "'$1' not found. Install it first (brew install $1  or  dnf install $1)."
}

wait_for_rollout() {
  local ns="$1" deploy="$2"
  kubectl rollout status deployment/"${deploy}" -n "${ns}" --timeout=5m
}

# Apply a remote manifest without going through the host proxy.
# kubectl uses Go's HTTP client which respects http_proxy/https_proxy; if
# those point at a corporate proxy that blocks GitHub, the download fails.
# Unsetting them here ensures direct access to public URLs.
kubectl_apply_url() {
  env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
      -u all_proxy  -u ALL_PROXY \
    kubectl apply -f "$1"
}

# ── prerequisites ──────────────────────────────────────────────────────────

log "Checking prerequisites"
require kind
require kubectl
require helm
require docker
ok "kind, kubectl, helm, docker — all found"

# ── Ingress prerequisites (istioctl + DNS) — only if ENABLE_INGRESS=true ─────

if [[ "${ENABLE_INGRESS}" == "true" ]]; then
  # ── istioctl: find in PATH, local cache, or download once ────────────────
  # Priority: system PATH → .cache/istioctl-<version> → download and cache
  ISTIOCTL_CACHE="${SCRIPT_DIR}/.cache/istioctl-${ISTIO_VERSION}"
  ISTIOCTL="$(command -v istioctl 2>/dev/null || true)"

  if [[ -z "${ISTIOCTL}" ]]; then
    if [[ -x "${ISTIOCTL_CACHE}" ]]; then
      ISTIOCTL="${ISTIOCTL_CACHE}"
      ok "istioctl ${ISTIO_VERSION} found in cache"
    else
      log "Downloading istioctl ${ISTIO_VERSION} (one-time, cached to .cache/)"
      TARGET_ARCH="$(uname -m)"
      ISTIO_TMP="$(mktemp -d /tmp/istio-XXXXXX)"
      trap 'rm -rf "${ISTIO_TMP}"' EXIT
      curl -sSL https://istio.io/downloadIstio \
        | ISTIO_VERSION="${ISTIO_VERSION}" TARGET_ARCH="${TARGET_ARCH}" sh - 2>&1
      mkdir -p "${SCRIPT_DIR}/.cache"
      cp "${SCRIPT_DIR}/istio-${ISTIO_VERSION}/bin/istioctl" "${ISTIOCTL_CACHE}"
      rm -rf "${SCRIPT_DIR}/istio-${ISTIO_VERSION}"
      ISTIOCTL="${ISTIOCTL_CACHE}"
      ok "istioctl ${ISTIO_VERSION} downloaded and cached"
    fi
  fi
  export PATH="$(dirname "${ISTIOCTL}"):${PATH}"

  # ── DNS check ──────────────────────────────────────────────────────────────
  log "Checking DNS: *.localhost.localdomain → 127.0.0.1"

  dns_resolves() {
    # dig bypasses /etc/resolver on macOS; dscacheutil uses the system resolver stack
    dscacheutil -q host -a name test.localhost.localdomain 2>/dev/null | grep -q "127.0.0.1"
  }

  if dns_resolves; then
    ok "DNS wildcard resolves (*.localhost.localdomain → 127.0.0.1)"
  else
    warn "*.localhost.localdomain does not resolve."
    echo
    warn "Run the following once (requires sudo), then re-run this script:"
    echo
    echo "  brew install dnsmasq"
    echo "  echo 'address=/.localhost.localdomain/127.0.0.1' >> \$(brew --prefix)/etc/dnsmasq.conf"
    echo "  sudo brew services start dnsmasq"
    echo "  sudo mkdir -p /etc/resolver"
    echo "  echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/localhost.localdomain"
    echo "  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
    echo
    die "Fix DNS first."
  fi
else
  warn "Skipping ingress prerequisites (ENABLE_INGRESS=false)"
fi

# ── storage root ───────────────────────────────────────────────────────────

log "Checking host storage root: ${STORAGE_ROOT}"

if [[ -d "${STORAGE_ROOT}" ]]; then
  ok "${STORAGE_ROOT} exists"
else
  die "${STORAGE_ROOT} does not exist. Run: sudo mkdir -p ${STORAGE_ROOT} && sudo chmod 777 ${STORAGE_ROOT}"
fi

# ── kind cluster ───────────────────────────────────────────────────────────

CLUSTER_EXISTS=false
kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$" && CLUSTER_EXISTS=true

if [[ "${RECREATE}" == "true" && "${CLUSTER_EXISTS}" == "true" ]]; then
  log "Deleting existing cluster '${CLUSTER_NAME}' (--recreate)"
  kind delete cluster --name "${CLUSTER_NAME}"
  CLUSTER_EXISTS=false
fi

if [[ "${CLEAN_STORAGE}" == "true" ]]; then
  log "Wiping host storage root: ${STORAGE_ROOT} (--clean-storage)"
  rm -rf "${STORAGE_ROOT:?}"/*
  ok "Storage root wiped"
fi

if [[ "${CLUSTER_EXISTS}" == "false" ]]; then
  log "Creating kind cluster '${CLUSTER_NAME}'"
  kind create cluster --config "${KIND_CONFIG}"
  ok "Cluster created"
else
  ok "Cluster '${CLUSTER_NAME}' already exists — reusing"
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

# ── Local Docker registry ──────────────────────────────────────────────────
#
# Run a registry:2 container on the kind Docker network so all cluster nodes
# can pull images from it as  kind-registry:5000/<image>:<tag>.
# From the host, push images to  localhost:${LOCAL_REGISTRY_PORT}/<image>:<tag>.
# Containerd on each node maps  localhost:${LOCAL_REGISTRY_PORT}  →
#   http://kind-registry:5000  (see configure_mirrors below) so pod specs
# can simply use  image: localhost:${LOCAL_REGISTRY_PORT}/<image>:<tag>.

start_local_registry() {
  if docker inspect "${LOCAL_REGISTRY_NAME}" &>/dev/null; then
    local state
    state=$(docker inspect -f '{{.State.Running}}' "${LOCAL_REGISTRY_NAME}")
    if [[ "${state}" == "true" ]]; then
      ok "Local registry '${LOCAL_REGISTRY_NAME}' already running (localhost:${LOCAL_REGISTRY_PORT})"
      return
    else
      docker start "${LOCAL_REGISTRY_NAME}" >/dev/null
      ok "Local registry '${LOCAL_REGISTRY_NAME}' started (was stopped)"
      return
    fi
  fi

  docker run -d \
    --name "${LOCAL_REGISTRY_NAME}" \
    --restart=always \
    -p "127.0.0.1:${LOCAL_REGISTRY_PORT}:5000" \
    registry:2 >/dev/null
  ok "Local registry '${LOCAL_REGISTRY_NAME}' started → localhost:${LOCAL_REGISTRY_PORT}"
}

connect_registry_to_kind_network() {
  # Attach the registry container to the kind Docker network so nodes can
  # resolve it by name as 'kind-registry'.
  if docker network inspect kind \
       --format '{{range .Containers}}{{.Name}} {{end}}' \
     | grep -qw "${LOCAL_REGISTRY_NAME}"; then
    ok "Registry already connected to 'kind' network"
  else
    docker network connect kind "${LOCAL_REGISTRY_NAME}"
    ok "Registry connected to 'kind' network"
  fi
}

if [[ "${ENABLE_REGISTRY}" == "true" ]]; then
  log "Starting local Docker registry"
  start_local_registry
  connect_registry_to_kind_network

  # Advertise the registry via the KEP-1755 standard ConfigMap so tools like
  # Tilt and Skaffold can discover it automatically.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${LOCAL_REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  ok "local-registry-hosting ConfigMap applied (kube-public/local-registry-hosting)"
else
  warn "Skipping local Docker registry (ENABLE_REGISTRY=false)"
fi

# ── Registry mirrors (containerd v2 hosts.toml) ────────────────────────────
#
# We configure mirrors by writing hosts.toml files into each node and
# restarting containerd — this is the correct method for containerd v2.
# The MIRRORS array can be edited freely; --recreate is NOT required.

# MIRRORS comes from .env (or the defaults set at the top of this script)

configure_mirrors() {
  local node="$1"

  # ── 1. Clear the broken host-injected proxy from containerd ─────────────────
  # Docker daemon injects HTTP_PROXY/HTTPS_PROXY into containers, but
  # 127.0.0.1 inside a container is the container itself (not the host proxy).
  # Override containerd's systemd unit to explicitly unset those variables.
  docker exec "${node}" bash -c "
    mkdir -p /etc/systemd/system/containerd.service.d
    cat > /etc/systemd/system/containerd.service.d/no-proxy.conf <<'UNIT'
[Service]
Environment='HTTP_PROXY='
Environment='HTTPS_PROXY='
Environment='http_proxy='
Environment='https_proxy='
Environment='ALL_PROXY='
Environment='all_proxy='
Environment='FTP_PROXY='
Environment='ftp_proxy='
UNIT
  " 2>&1 | sed "s/^/  [${node}] /"

  # ── 2. Write hosts.toml for docker.io (pre-generated on host) ───────────────
  # Build the TOML content here to avoid quoting issues inside docker exec "..."
  local dockerio_toml
  dockerio_toml='server = "https://registry-1.docker.io"'$'\n'
  for m in "${MIRRORS[@]}"; do
    dockerio_toml+='[host."'"${m}"'"]'$'\n'
    dockerio_toml+='  capabilities = ["pull", "resolve"]'$'\n\n'
  done
  printf '%s' "${dockerio_toml}" | docker exec -i "${node}" bash -c \
    'mkdir -p /etc/containerd/certs.d/docker.io && cat > /etc/containerd/certs.d/docker.io/hosts.toml' \
    2>&1 | sed "s/^/  [${node}] /"

  # ── 3. Point containerd at the certs.d directory (idempotent) ───────────────
  docker exec "${node}" bash -c "
    if ! grep -q 'config_path' /etc/containerd/config.toml 2>/dev/null; then
      cat >> /etc/containerd/config.toml <<'CONF'

# Added by setup.sh — enable certs.d mirrors
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'
CONF
    fi
  " 2>&1 | sed "s/^/  [${node}] /"

  # ── 4. Configure local registry mirror ──────────────────────────────────────
  # Pod specs use  localhost:${LOCAL_REGISTRY_PORT}/image:tag
  # Inside the node localhost:${LOCAL_REGISTRY_PORT} doesn't reach the host,
  # so we redirect that address to the registry container on the kind network.
  # Build content on the host to avoid double-quote stripping inside "..." strings.
  local registry_toml
  registry_toml='[host."http://'"${LOCAL_REGISTRY_NAME}"':5000"]'$'\n'
  registry_toml+='  capabilities = ["pull", "resolve"]'$'\n'
  printf '%s' "${registry_toml}" | docker exec -i "${node}" bash -c \
    "mkdir -p /etc/containerd/certs.d/localhost:${LOCAL_REGISTRY_PORT} && cat > /etc/containerd/certs.d/localhost:${LOCAL_REGISTRY_PORT}/hosts.toml" \
    2>&1 | sed "s/^/  [${node}] /"

  # ── 5. Reload and restart containerd ────────────────────────────────────────
  docker exec "${node}" bash -c "
    systemctl daemon-reload
    systemctl restart containerd
    sleep 2
    echo 'containerd restarted'
  " 2>&1 | sed "s/^/  [${node}] /"
}

if [[ "${ENABLE_REGISTRY}" == "true" ]]; then
  log "Configuring Docker Hub mirrors + local registry redirect on all kind nodes"
  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    configure_mirrors "${node}"
  done
  ok "Registry mirrors configured"
else
  warn "Skipping registry mirrors / containerd config (ENABLE_REGISTRY=false)"
fi

# ── local-path-provisioner ─────────────────────────────────────────────────

log "Configuring local-path-provisioner"

# kind v0.31+ ships local-path-provisioner in local-path-storage namespace.
# We do NOT replace it (avoids pulling external images); we only patch the
# ConfigMap to redirect storage to our host-mounted path.
kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=3m

kubectl patch configmap local-path-config \
  -n local-path-storage \
  --type merge \
  -p "{\"data\":{\"config.json\":\"{\\\"nodePathMap\\\":[{\\\"node\\\":\\\"DEFAULT_PATH_FOR_NON_LISTED_NODES\\\",\\\"paths\\\":[\\\"${STORAGE_ROOT}\\\"]}]}\"}}"

# Bounce the pod so it picks up the new ConfigMap
kubectl rollout restart deployment/local-path-provisioner -n local-path-storage
kubectl rollout status  deployment/local-path-provisioner -n local-path-storage --timeout=3m

# Auto-detect the StorageClass backed by rancher.io/local-path (may be called
# 'local-path' or 'standard' depending on the kind version).
LOCAL_PATH_SC=$(kubectl get storageclass \
  -o jsonpath='{range .items[?(@.provisioner=="rancher.io/local-path")]}{.metadata.name}{end}')

if [[ -n "${LOCAL_PATH_SC}" ]]; then
  kubectl patch storageclass "${LOCAL_PATH_SC}" \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  ok "StorageClass '${LOCAL_PATH_SC}' set as default"
else
  warn "Could not find a rancher.io/local-path StorageClass — skipping"
fi

ok "local-path-provisioner configured (storage root: ${STORAGE_ROOT})"

# ── Ingress stack (cert-manager + Gateway API + Istio + …) ────────────────
#
# Single ENABLE_INGRESS gate wraps every ingress-related install step below.
# Skipping leaves only the bare kind cluster + local-path-provisioner +
# (optionally) the local registry.

if [[ "${ENABLE_INGRESS}" == "true" ]]; then

log "Installing ServiceMonitor CRD"
kubectl_apply_url https://github.com/Netcracker/qubership-monitoring-operator/raw/refs/heads/main/charts/qubership-monitoring-crds/crds/monitoring.coreos.com_servicemonitors.yaml

# ── cert-manager ───────────────────────────────────────────────────────────

log "Installing cert-manager ${CERT_MANAGER_VERSION}"

helm repo add jetstack https://charts.jetstack.io --force-update 2>/dev/null || true
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --wait --timeout 5m

ok "cert-manager installed"

log "Creating self-signed ClusterIssuers"

# Wait for cert-manager webhook to be ready
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=2m

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: local-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: ${CLUSTER_NAME}-ca
  secretName: local-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: local-ca-issuer
spec:
  ca:
    secretName: local-ca-secret
EOF

# Wait for the CA certificate to be issued
echo "  Waiting for local CA certificate..."
for i in $(seq 1 30); do
  if kubectl get secret local-ca-secret -n cert-manager &>/dev/null; then
    ok "ClusterIssuers ready (selfsigned-issuer, local-ca-issuer)"
    break
  fi
  sleep 2
done

# ── Kubernetes Gateway API CRDs ────────────────────────────────────────────
#
# Must be installed before Istio so Istio's Gateway API controller can
# register watches on these resource types at startup.

log "Installing Kubernetes Gateway API CRDs ${GATEWAY_API_VERSION}"

kubectl_apply_url "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

ok "Gateway API CRDs installed"

# ── Istio ──────────────────────────────────────────────────────────────────

log "Installing Istio ${ISTIO_VERSION} via Helm"

helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update 2>/dev/null || true
helm repo update istio

# CRDs + cluster-wide RBAC
helm upgrade --install istio-base istio/base \
  --namespace istio-system \
  --create-namespace \
  --version "${ISTIO_VERSION}" \
  --wait --timeout 3m

# Control plane
# ingressControllerMode=DEFAULT means Istio only claims Ingress resources that
# explicitly select it (spec.ingressClassName: istio or the legacy annotation).
# ingressService=gateway-istio: Istio reads Ingress routes and pushes config to
# the gateway-istio pod (auto-created by the Gateway API deployment controller).
# This eliminates the need for a separate istio-ingressgateway deployment.
helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --version "${ISTIO_VERSION}" \
  --set meshConfig.ingressClass=istio \
  --set meshConfig.ingressControllerMode=DEFAULT \
  --set meshConfig.ingressService=gateway-istio \
  --wait --timeout 5m

kubectl label namespace default istio-injection=enabled --overwrite

ok "Istio control plane installed"

# Register an IngressClass so that spec.ingressClassName: istio works (Kubernetes
# 1.18+ style). The legacy annotation kubernetes.io/ingress.class: istio still
# works too (handled by meshConfig.ingressClass above).
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: istio
spec:
  controller: istio.io/ingress-controller
EOF
ok "IngressClass 'istio' registered"

# ── Wildcard TLS cert for Istio gateway ───────────────────────────────────
#
# For HTTPS Gateways the TLS secret must live in istio-system (where the
# gateway pod runs). We provision a wildcard cert once; per-service Gateways
# can reference it via  spec.servers[].tls.credentialName: istio-gw-tls
# (or create their own certs in istio-system using the same pattern).

log "Creating wildcard TLS cert for Istio gateway (istio-system)"

kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-gw-tls
  namespace: istio-system
spec:
  secretName: istio-gw-tls
  commonName: "*.localhost.localdomain"
  dnsNames:
    - "*.localhost.localdomain"
    - "localhost.localdomain"
  issuerRef:
    name: local-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
EOF

echo "  Waiting for istio-gw-tls secret..."
for i in $(seq 1 30); do
  if kubectl get secret istio-gw-tls -n istio-system &>/dev/null; then
    ok "Wildcard TLS cert ready (secret: istio-system/istio-gw-tls)"
    break
  fi
  sleep 2
done

# ── Kubernetes Gateway API: shared Gateway resource ───────────────────────
#
# Creates a single shared Gateway in 'istio-system' that all HTTPRoute and
# classic Ingress resources share.  The Gateway API deployment controller
# auto-creates a 'gateway-istio' Deployment + Service here.
# meshConfig.ingressService=gateway-istio (set above) tells Istiod to push
# Ingress routes to this same pod — one gateway handles everything.
# The TLS secret (istio-gw-tls) lives in istio-system next to the gateway pod.

# Wait for GatewayClass 'istio' — Istio registers it after the CRDs are present
echo "  Waiting for GatewayClass 'istio'..."
for i in $(seq 1 30); do
  if kubectl get gatewayclass istio &>/dev/null 2>&1; then
    ok "GatewayClass 'istio' is available"
    break
  fi
  sleep 2
done

kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gateway
  namespace: istio-system
spec:
  gatewayClassName: istio
  infrastructure:
    labels:
      # Istiod's Ingress controller selects gateway pods via {istio: <ingressService>}
      # (hardcoded pattern, independent of the Service's actual pod selector).
      # This label makes meshConfig.ingressService=gateway-istio work for classic Ingress.
      istio: gateway-istio
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: istio-gw-tls
            namespace: istio-system
      allowedRoutes:
        namespaces:
          from: All
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF

ok "Gateway 'istio-system/gateway' created (HTTPS :443, HTTP :80)"

# The Gateway API deployment controller creates the gateway-istio pod with a
# ServiceAccount that lacks permission to read K8s secrets.  But Istio's classic
# Ingress controller generates TLS filter chains that use the 'kubernetes://'
# SDS scheme, which requires the pod to read secrets directly via the K8s API.
# Without this Role, classic Ingress TLS stays stuck in 'warming' and TLS
# connections fail immediately (EOF after Client Hello).
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gateway-istio-secret-reader
  namespace: istio-system
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gateway-istio-secret-reader
  namespace: istio-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: gateway-istio-secret-reader
subjects:
  - kind: ServiceAccount
    name: gateway-istio
    namespace: istio-system
EOF
ok "gateway-istio ServiceAccount granted secrets read access (for Ingress TLS)"

# ── Patch gateway-istio Service to fixed NodePorts ────────────────────────
#
# Istio's Gateway API deployment controller auto-creates 'gateway-istio'
# Deployment + Service in istio-system after the Gateway resource is applied.
# We patch the Service to use fixed NodePorts so kind's host port mappings
# (kind-config.yaml: host:80→30080, host:443→30443) reach the right pods.

log "Waiting for Istio to provision gateway-istio Service in istio-system"
for i in $(seq 1 60); do
  if kubectl get svc gateway-istio -n istio-system &>/dev/null; then
    ok "Service gateway-istio found"
    break
  fi
  if [[ "${i}" -eq 60 ]]; then
    die "Timed out waiting for gateway-istio Service — check Istiod logs"
  fi
  sleep 3
done

log "Patching gateway-istio Service → NodePort ${ISTIO_NODEPORT_HTTP} (HTTP) / ${ISTIO_NODEPORT_HTTPS} (HTTPS)"
kubectl patch svc gateway-istio -n istio-system --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},
  {\"op\":\"replace\",\"path\":\"/spec/ports\",\"value\":[
    {\"name\":\"status-port\",\"port\":15021,\"targetPort\":15021,\"protocol\":\"TCP\"},
    {\"name\":\"http\",       \"port\":80,   \"targetPort\":80,   \"nodePort\":${ISTIO_NODEPORT_HTTP},\"protocol\":\"TCP\"},
    {\"name\":\"https\",      \"port\":443,  \"targetPort\":443,  \"nodePort\":${ISTIO_NODEPORT_HTTPS},\"protocol\":\"TCP\"}
  ]}
]"
ok "gateway-istio → NodePort ${ISTIO_NODEPORT_HTTP} (HTTP→host:${ISTIO_HTTP_PORT}) / ${ISTIO_NODEPORT_HTTPS} (HTTPS→host:${ISTIO_HTTPS_PORT})"

else
  warn "Skipping ingress stack: cert-manager, Gateway API, Istio, IngressClass, wildcard TLS, RBAC, NodePort patch, ServiceMonitor CRD (ENABLE_INGRESS=false)"
fi

# ── Verify ────────────────────────────────────────────────────────────────

log "Verifying cluster components"

echo
printf "  %-40s %s\n" "COMPONENT" "STATUS"
printf "  %-40s %s\n" "---------" "------"

check_deployment() {
  local ns="$1" name="$2"
  local ready
  ready=$(kubectl get deployment "${name}" -n "${ns}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  local desired
  desired=$(kubectl get deployment "${name}" -n "${ns}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  if [[ "${ready}" == "${desired}" && "${ready}" != "0" ]]; then
    printf "  %-40s \033[1;32m%s/%s ready\033[0m\n" "${ns}/${name}" "${ready}" "${desired}"
  else
    printf "  %-40s \033[1;33m%s/%s ready\033[0m\n" "${ns}/${name}" "${ready:-0}" "${desired}"
  fi
}

check_deployment local-path-storage   local-path-provisioner
if [[ "${ENABLE_INGRESS}" == "true" ]]; then
  check_deployment cert-manager         cert-manager
  check_deployment cert-manager         cert-manager-webhook
  check_deployment istio-system         istiod
  check_deployment istio-system         gateway-istio
fi

echo
kubectl get storageclass
echo

# ── Summary ────────────────────────────────────────────────────────────────

cat <<SUMMARY

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Cluster '${CLUSTER_NAME}' is ready
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Features: ingress=${ENABLE_INGRESS}  registry=${ENABLE_REGISTRY}
SUMMARY

if [[ "${ENABLE_INGRESS}" == "true" ]]; then
cat <<SUMMARY

  Single gateway (gateway-istio in istio-system) handles all traffic on ${ISTIO_HTTP_PORT}/${ISTIO_HTTPS_PORT}.

  Kubernetes Gateway API (HTTPRoute — recommended for new apps):
    HTTP   →  http://<name>.localhost.localdomain:${ISTIO_HTTP_PORT}
    HTTPS  →  https://<name>.localhost.localdomain:${ISTIO_HTTPS_PORT}
    parentRef: istio-system/gateway  (gatewayClassName: istio)

  Classic Ingress (set ingressClassName: istio):
    HTTP   →  http://<name>.localhost.localdomain:${ISTIO_HTTP_PORT}
    HTTPS  →  https://<name>.localhost.localdomain:${ISTIO_HTTPS_PORT} (add tls: + secretName: istio-gw-tls)

  Istio Gateway + VirtualService (Istio native):
    HTTP   →  http://<name>.localhost.localdomain:${ISTIO_HTTP_PORT}
    HTTPS  →  https://<name>.localhost.localdomain:${ISTIO_HTTPS_PORT}
    TLS credential: istio-gw-tls  (secret in istio-system)
SUMMARY
fi

if [[ "${ENABLE_REGISTRY}" == "true" ]]; then
cat <<SUMMARY

  Local registry (push once, all nodes pull):
    Build : ./kbuild <image>:<tag> <context_path>
    In pod: image: localhost:${LOCAL_REGISTRY_PORT}/<image>:<tag>
SUMMARY
fi

cat <<SUMMARY

  Storage:
    StorageClass : local-path (default)
    Host path    : ${STORAGE_ROOT}

  Re-run modes:
    ./setup.sh                            — upgrade components in-place
    ./setup.sh --recreate                 — delete + recreate cluster (keeps host storage)
    ./setup.sh --recreate --clean-storage — delete + recreate cluster + wipe ${STORAGE_ROOT}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY
