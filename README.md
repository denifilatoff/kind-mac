# Local kind Kubernetes cluster

> **macOS only.** This setup is tested and supported on macOS exclusively.

## TL;DR

A script-driven local Kubernetes cluster for development on macOS. One command gives you:

- **kind** cluster (1 control-plane + 2 workers) — always
- **persistent storage** backed by a host directory — always
- **Istio** service mesh + single ingress gateway on ports 80/443 (HTTPRoute, classic Ingress, Istio Gateway+VirtualService) — optional, `ENABLE_INGRESS`
- **cert-manager** with a self-signed CA (automatic TLS for `*.localhost.localdomain`) — part of ingress
- **local Docker registry** on `localhost:5001` (no `kind load` needed) — optional, `ENABLE_REGISTRY`

---

## Quick start

```bash
# 1. One-time: DNS + storage (see details below)
brew install dnsmasq
echo 'address=/.localhost.localdomain/127.0.0.1' >> $(brew --prefix)/etc/dnsmasq.conf
sudo brew services start dnsmasq
sudo mkdir -p /etc/resolver
echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/localhost.localdomain
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
sudo mkdir -p /var/local-path-provisioner && sudo chmod 777 /var/local-path-provisioner

# 2. Copy and (optionally) edit cluster config
cp .env.example .env

# 3. Create the cluster
./setup.sh

# 4. Verify everything works
./smoke-test.sh

# Recreate the cluster from scratch + wipe persistent storage
./setup.sh --recreate --clean-storage
```

---

## Architecture

```
macOS host
  *.localhost.localdomain → 127.0.0.1  (dnsmasq)
       │
       └── :80 / :443  ──► kind node NodePort ──► gateway-istio (istio-system)
                            30080 / 30443          ├── HTTPRoute  (Gateway API)
                                                   ├── Ingress    (ingressClassName: istio)
                                                   └── Gateway + VirtualService (Istio native)

  localhost:5001  ──► kind-registry container ──► all kind nodes (containerd mirror)
```

| Entry point                     | Host port    | Used for                                   |
|---------------------------------|--------------|--------------------------------------------|
| `gateway-istio` (istio-system)  | 80 / **443** | `HTTPRoute` · `Ingress` · `VirtualService` |
| Local registry                  | 5001         | Push images, pods pull automatically       |
| Storage                         | —            | `/var/local-path-provisioner`              |

A single `istio-system/gateway` Gateway accepts HTTPRoutes from **any namespace**
on HTTP (:80) and HTTPS (:443). TLS is terminated using the wildcard cert
`istio-system/istio-gw-tls` (issued by `local-ca-issuer`).

Classic `Ingress` resources (`ingressClassName: istio`) and Istio-native
`Gateway`+`VirtualService` are also served by the same `gateway-istio` pod
(configured via `meshConfig.ingressService=gateway-istio` in Istiod).

---

## Prerequisites

Install required tools via Homebrew:

```bash
brew install kind kubectl helm docker
```

Start Docker Desktop (or any Docker-compatible runtime) before running `setup.sh`.

> **istioctl** is downloaded automatically by `setup.sh` if not found in `PATH`.
> To install manually: `curl -sSL https://istio.io/downloadIstio | sh -`

---

## One-time setup

### DNS — wildcard `*.localhost.localdomain`

macOS does not support wildcard entries in `/etc/hosts`. Instead, we use two
components working together:

**dnsmasq** — a lightweight DNS server that runs locally and resolves any
hostname matching `*.localhost.localdomain` to `127.0.0.1`. It is installed via
Homebrew and runs as a user-space service on `127.0.0.1:53`.

**`/etc/resolver/`** — a macOS-specific directory where each file name is a DNS
suffix and its content points to a nameserver for that suffix. By creating
`/etc/resolver/localhost.localdomain` with `nameserver 127.0.0.1`, macOS routes
all `*.localhost.localdomain` lookups to dnsmasq instead of the system DNS.

> `dig` bypasses `/etc/resolver` on macOS. Use `dscacheutil` or `ping` to test.

```bash
# Install and configure dnsmasq
brew install dnsmasq
echo 'address=/.localhost.localdomain/127.0.0.1' >> $(brew --prefix)/etc/dnsmasq.conf
sudo brew services start dnsmasq

# Point macOS resolver for the .localhost.localdomain suffix to dnsmasq
sudo mkdir -p /etc/resolver
echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/localhost.localdomain

# Flush DNS cache and reload mDNSResponder
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder

# Verify (should return 127.0.0.1)
dscacheutil -q host -a name anything.localhost.localdomain
```

If dnsmasq stops after a reboot:

```bash
sudo brew services restart dnsmasq
```

### Host storage

The local-path-provisioner stores PVC data on the host. Create the directory once:

```bash
sudo mkdir -p /var/local-path-provisioner
sudo chmod 777 /var/local-path-provisioner
```

Data here **survives cluster deletion** as long as you don't remove the directory.

---

## Configuration

Copy `.env.example` to `.env` and adjust as needed:

```bash
cp .env.example .env
```

Key options (all have sensible defaults):

```bash
CLUSTER_NAME=local-dev
K8S_VERSION=v1.35.0
ISTIO_VERSION=1.23.3
CERT_MANAGER_VERSION=v1.16.2
STORAGE_ROOT=/var/local-path-provisioner
LOCAL_REGISTRY_PORT=5001

# Docker Hub mirrors — tried in order, original registry used as fallback.
# Edit freely; re-run ./setup.sh to apply (no --recreate needed).
MIRRORS=(
  "https://dockerhub.timeweb.cloud"
  "https://dockerhub1.beget.com"
  "https://mirror.gcr.io"
)

# Feature toggles — set to "false" to skip a whole block of components
ENABLE_INGRESS=true    # cert-manager + Gateway API + Istio + IngressClass + wildcard TLS + ServiceMonitor CRD + DNS check
ENABLE_REGISTRY=true   # local kind-registry + Docker Hub mirrors + containerd no-proxy
```

Precedence: **env var > `.env` > in-script default**. So you can pin a flag in
`.env` and still override it for a one-off run via the command line.

---

## Running the cluster

```bash
# Create cluster + install/upgrade all components (idempotent)
./setup.sh

# Delete and recreate from scratch (keeps host storage)
./setup.sh --recreate
```

### Custom cluster name

By default the cluster is named `local-dev` (from `.env.example`). To create
a cluster with a different name, override `CLUSTER_NAME` — either edit `.env`
or pass it inline for a one-off run:

```bash
# Option 1: edit .env permanently
echo 'CLUSTER_NAME=my-cluster' >> .env
./setup.sh

# Option 2: inline override (does not modify .env)
CLUSTER_NAME=my-cluster ./setup.sh

# Switch kubectl context to the new cluster
kubectl config use-context kind-my-cluster

# Tear it down later (must pass the same name)
kind delete cluster --name my-cluster
```

> Running multiple kind clusters at once requires unique `ISTIO_HTTP_PORT` /
> `ISTIO_HTTPS_PORT` values per cluster — only one cluster can bind host
> ports 80/443 at a time.

### Optional features

Two large blocks of `setup.sh` can be skipped via flags. Persistent storage
and the kind cluster itself are always created.

| Flag | Default | What it controls |
|------|---------|------------------|
| `ENABLE_INGRESS` | `true` | DNS-wildcard check, `istioctl` auto-download, cert-manager + self-signed CA, Gateway API CRDs, Istio control plane, `IngressClass istio`, shared `Gateway`, wildcard TLS secret, RBAC for `gateway-istio`, NodePort patch, ServiceMonitor CRD |
| `ENABLE_REGISTRY` | `true` | `kind-registry` container + KEP-1755 ConfigMap, Docker Hub mirrors, containerd no-proxy override, `localhost:5001` → `kind-registry:5000` redirect |

```bash
# Skip the whole ingress stack — leaves a bare cluster + storage + local registry
ENABLE_INGRESS=false ./setup.sh --recreate

# Skip the local registry block — leaves a bare cluster + storage + ingress
ENABLE_REGISTRY=false ./setup.sh --recreate

# Both off — minimal cluster: just kind nodes + local-path-provisioner
ENABLE_INGRESS=false ENABLE_REGISTRY=false ./setup.sh --recreate
```

The smoke test assumes ingress is on; with `ENABLE_INGRESS=false` it will
fail on the HTTPRoute and Istio-sidecar checks.

---

## Smoke test

Verifies all cluster components are working correctly:

```bash
./smoke-test.sh
```

Checks: DNS resolution, Istio HTTP/HTTPS ingress (Gateway API + classic Ingress),
PVC provisioning, and Istio sidecar injection.

Creates a temporary `smoke-test` namespace, runs the tests, and deletes the namespace
on success. On failure it leaves resources in place for investigation.

---

## Usage

### Kubernetes Gateway API with HTTPRoute (recommended)

`setup.sh` creates a shared `Gateway` in `istio-system` backed by the
`gateway-istio` pod on ports 80/443. HTTPRoutes from any namespace attach to
it via `parentRefs`.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-namespace
spec:
  parentRefs:
    - name: gateway
      namespace: istio-system
  hostnames:
    - my-app.localhost.localdomain
  rules:
    - backendRefs:
        - name: my-app-svc
          port: 80
```

Access: `https://my-app.localhost.localdomain` (HTTPS terminated at the Gateway
using the wildcard cert `istio-system/istio-gw-tls`).

---

### Classic Ingress with automatic TLS

Use `ingressClassName: istio` instead of `nginx`. For HTTPS, reference the
shared wildcard secret `istio-gw-tls` (in `istio-system`) in the `tls:` block —
Istio reads it from there and terminates TLS for the matching hostname.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
spec:
  ingressClassName: istio
  tls:
    - hosts: [my-app.localhost.localdomain]
      secretName: istio-gw-tls   # shared wildcard cert in istio-system
  rules:
    - host: my-app.localhost.localdomain
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app-svc
                port:
                  number: 80
```

Access: `https://my-app.localhost.localdomain`

---

### Istio Gateway + VirtualService (Istio native)

`setup.sh` provisions a wildcard TLS certificate (`istio-system/istio-gw-tls`) shared
by all Gateways via `credentialName`.

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: my-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts: [my-app.localhost.localdomain]
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: istio-gw-tls   # shared wildcard cert from setup.sh
      hosts: [my-app.localhost.localdomain]
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: my-app
spec:
  hosts: [my-app.localhost.localdomain]
  gateways: [my-gateway]
  http:
    - route:
        - destination:
            host: my-app-svc
            port:
              number: 80
```

Access:
- HTTP:  `http://my-app.localhost.localdomain`
- HTTPS: `https://my-app.localhost.localdomain`

> **Per-service TLS**: create a `Certificate` in `istio-system` with your desired
> `secretName` and reference it as `credentialName` in the Gateway.

---

### Persistent Volume Claim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path   # default — can be omitted
  resources:
    requests:
      storage: 5Gi
```

---

### Local Docker registry

`setup.sh` starts a `registry:2` container (`kind-registry`) connected to the kind
Docker network. Containerd on every node redirects `localhost:5001` →
`http://kind-registry:5000`, so pod specs use `image: localhost:5001/<name>:<tag>`
and the image is pulled from the local registry automatically.

**Build and push in one step** with `kbuild`:

```bash
./kbuild my-service:latest .
./kbuild my-service:latest --build-arg ENV=dev .
./kbuild my-service:latest --file ./docker/Dockerfile .
```

Reference in pod spec:

```yaml
spec:
  containers:
    - name: my-service
      image: localhost:5001/my-service:latest
      imagePullPolicy: Always   # re-pull on every pod restart
```

> Use `imagePullPolicy: Always` with mutable tags like `latest` so
> `kubectl rollout restart` always picks up the freshly pushed image.

Inspect registry contents:

```bash
curl -s http://localhost:5001/v2/_catalog | jq
curl -s http://localhost:5001/v2/my-service/tags/list | jq
```

---

## Trust the self-signed CA in your browser

```bash
# Export the CA certificate
kubectl get secret local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > local-ca.crt

# Add to macOS system keychain and trust it
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain local-ca.crt

# Restart your browser
```

---

## Tear down

```bash
# Use the cluster name from your .env (default: local-dev)
kind delete cluster --name local-dev

# Optional — removes all persistent data
sudo rm -rf /var/local-path-provisioner
```

---

## Registry mirrors / Docker Hub proxy

`setup.sh` writes containerd `hosts.toml` files directly into each node and
restarts containerd — **no cluster recreation required**. Edit the `MIRRORS`
array in `.env` and re-run:

```bash
MIRRORS=(
  "https://dockerhub.timeweb.cloud"
  "https://dockerhub1.beget.com"
  "https://mirror.gcr.io"
)
```

```bash
./setup.sh   # idempotent — reconfigures mirrors on the running cluster
```

Mirrors are tried in order; the original registry is used as a fallback.

To verify mirrors are active on a running node:

```bash
docker exec ${CLUSTER_NAME}-control-plane \
  cat /etc/containerd/certs.d/docker.io/hosts.toml
```

---


## Troubleshooting

| Problem | Fix |
|---------|-----|
| Port 80/443 already in use | Stop any local web server: `sudo lsof -i :80` |
| DNS not resolving | Check dnsmasq is running: `sudo brew services list \| grep dnsmasq`; flush cache: `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder` |
| Ingress not routing | Confirm `ingressClassName: istio` is set (not `nginx`) |
| Istio pods pending | Ensure Docker Desktop has ≥ 4 CPU / 8 GB RAM allocated |
| TLS cert not issued | `kubectl describe certificaterequest -A` and check cert-manager logs |
| ImagePullBackOff (public image) | Edit `MIRRORS` in `.env`, re-run `./setup.sh` (no `--recreate` needed) |
| ImagePullBackOff (local image) | `./kbuild <image>:<tag> <context>`; use `localhost:5001/…` in pod spec |
| smoke-test DNS check fails | Verify `/etc/resolver/localhost.localdomain` exists and dnsmasq is running |
