# Istio Ambient Mode Declarative GitOps Repository

This private repository is the declarative source of truth for **Istio Ambient Mode** service mesh configurations on **Google Kubernetes Engine (GKE)**, managed and synchronized via **Argo CD**.

---

## 1. Overview & Architecture

Istio Ambient Mode delivers a transparent, sidecarless service mesh architecture:

```text
               +-------------------------------------------+
               |             Istiod Control Plane          |
               |        (profile: ambient, xDS / CA)       |
               +---------------------+---------------------+
                                     |
               +---------------------+---------------------+
               |       Istio CNI (GKE Node DaemonSet)      |
               |   (/home/kubernetes/bin & /etc/cni/net.d) |
               +---------------------+---------------------+
                                     |
                                     v
+------------------------------------+------------------------------------+
|                         GKE Worker Node                                 |
|                                                                         |
|  +--------------------+                     +------------------------+  |
|  | Application Pod A  |                     |  Application Pod B     |  |
|  | (apps-ambient)     |                     |  (apps-ambient)        |  |
|  +---------+----------+                     +-----------^------------+  |
|            |                                            |               |
|            v (Transparent redirection via CNI)          |               |
|  +------------------------------------------------------+------------+  |
|  |                   ztunnel (Zero-Trust Tunnel)                     |  |
|  |           mTLS (HBONE :15008), L4 telemetry & L4 Authz            |  |
|  +-------------------------------------------------------------------+  |
+------------------------------------+------------------------------------+
                                     |
                       (Optional Layer 7 processing)
                                     v
                        +-------------------------+
                        |  Waypoint Proxy (Envoy) |
                        |  L7 Authz, Metrics, API |
                        +-------------------------+
```

### Key Components:
- **`ztunnel` (Zero-Trust Tunnel)**: High-performance node proxy DaemonSet handling mutual TLS (mTLS via HBONE on port 15008), zero-trust authentication, and Layer 4 telemetry without application pod modification or sidecars.
- **`istio-cni`**: Node DaemonSet configured for GKE's container runtime paths (`/home/kubernetes/bin` and `/etc/cni/net.d`) that redirects traffic from enrolled pods into the local `ztunnel`.
- **`istiod`**: Ambient-enabled control plane providing xDS configuration and mTLS certificates.
- **`waypoint`**: Standalone Envoy proxies deployed per-namespace or per-service to handle Layer 7 traffic routing and authorization policies when needed.

---

## 2. Repository Structure

```text
.
├── argocd/
│   ├── app-of-apps.yaml               # Parent root application reconciling all clusters
│   ├── repo-secret.template.yaml      # Secret template for Argo CD private Git authentication
│   ├── base/                          # Shared base Argo CD application manifests
│   │   ├── kustomization.yaml
│   │   ├── 00-istio-base.yaml         # Wave 0: Base CRDs & RBAC
│   │   ├── 01-istio-cni.yaml          # Wave 1: CNI DaemonSet
│   │   ├── 01-istiod.yaml             # Wave 1: Istiod Control Plane
│   │   ├── 02-istio-ztunnel.yaml      # Wave 2: Ztunnel L4 Node Proxy
│   │   ├── 03-istio-policies.yaml     # Wave 3: STRICT mTLS & Auth Policies
│   │   └── 04-ambient-samples.yaml    # Wave 4: apps-ambient sample workloads & waypoint
│   └── clusters/                      # Dedicated cluster overlays
│       ├── argocd-control-plane/      # Control Plane cluster configuration
│       │   ├── kustomization.yaml
│       │   ├── cluster-config.yaml
│       │   └── 05-argocd.yaml         # Self-managing Argo CD Application on control plane
│       ├── gke-managed-cluster/       # Managed cluster 1 configuration
│       │   ├── kustomization.yaml
│       │   └── cluster-config.yaml
│       └── gke-managed-cluster-2/     # Managed cluster 2 configuration
│           ├── kustomization.yaml
│           └── cluster-config.yaml
├── manifests/                         # Declarative platform manifests
│   └── argocd/                        # Argo CD control plane Kustomize manifests
│       ├── kustomization.yaml         # Injects Workload Identity annotations
│       └── install.yaml               # Upstream Argo CD install manifests
├── charts/                            # Helm wrapper charts with upstream dependencies
│   ├── istio-base/                    # Upstream base chart + values
│   ├── istio-cni/                     # Upstream CNI chart + GKE values
│   ├── istiod/                        # Upstream istiod chart + ambient values
│   ├── istio-ztunnel/                 # Upstream ztunnel chart + values
│   └── istio-waypoint/                # Upstream gateway chart for L7 Waypoint
├── policies/                          # Mesh Security Policies (Kustomize)
│   ├── namespace.yaml                 # istio-system namespace
│   ├── apps-ambient-namespace.yaml    # apps-ambient namespace with ambient label
│   ├── peer-authentication.yaml       # Mesh-wide STRICT mutual TLS
│   ├── authorization-policies.yaml    # L4 and L7 Authorization policies
│   └── telemetry.yaml                 # Access logging and Prometheus metrics
├── samples/                           # Verification Workloads (Kustomize)
│   ├── echo-server.yaml               # Target microservice
│   ├── sleep-client.yaml              # Testing client
│   └── waypoint-gateway.yaml          # L7 Waypoint Gateway (istio-waypoint)
```

---

## 3. Configuring Argo CD to Access this Private Repository

Because this repository is **private**, Argo CD requires credentials to pull chart definitions and manifests.

Apply the following secret to the `argocd` namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: repo-istio-ambient-config
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/wilsonfv/istio-ambient-config.git
  username: oauth2
  password: <GITHUB_PAT_TOKEN>
```

---

## 4. Deploying & Syncing to GKE via Argo CD

Multi-cluster automation and lifecycle are driven by the platform repository:
👉 [**github.com/wilsonfv/argocd-crossplane-gcp**](https://github.com/wilsonfv/argocd-crossplane-gcp)

To deploy across all clusters directly using the platform automation:
```bash
./deploy-istio-ambient.sh
```

Or apply the declarative parent App-of-Apps manifest directly to the Argo CD control plane:
```bash
kubectl apply -f argocd/app-of-apps.yaml
```

---

## 5. Sync Waves & Deployment Sequence

Argo CD deploys the mesh components deterministically using sync waves:

| Wave | Application | Path | Description |
|---|---|---|---|
| **0** | `istio-base` | `charts/istio-base` | Istio CRDs and base cluster roles |
| **1** | `istio-cni` | `charts/istio-cni` | CNI DaemonSet with GKE paths (`/home/kubernetes/bin`) |
| **1** | `istiod` | `charts/istiod` | Ambient Control Plane (`PILOT_ENABLE_AMBIENT=true`) |
| **2** | `istio-ztunnel` | `charts/istio-ztunnel` | Node-level Zero Trust Tunnel proxy DaemonSet |
| **3** | `istio-policies` | `policies` | STRICT mTLS `PeerAuthentication`, L4/L7 Authz |
| **4** | `ambient-samples` | `samples` | `apps-ambient` namespace, workloads, and Waypoint proxy |

---

## 6. Verification & Validation

### 1. Verify Argo CD Application Status
```bash
kubectl get applications.argoproj.io -n argocd
```
Expected output:
```text
NAME                 SYNC STATUS   HEALTH STATUS
istio-ambient-root   Synced        Healthy
istio-base           Synced        Healthy
istio-cni            Synced        Healthy
istiod               Synced        Healthy
istio-ztunnel        Synced        Healthy
istio-policies       Synced        Healthy
ambient-samples      Synced        Healthy
```

### 2. Verify Istio Ambient Pods
```bash
kubectl get pods -n istio-system -o wide
```
Ensure:
- `istiod-*` is `Running` (1/1)
- `istio-cni-node-*` DaemonSet pods are `Running` on every GKE node
- `ztunnel-*` DaemonSet pods are `Running` on every GKE node

### 3. Verify Mutual TLS & L4 Traffic Flow
Execute a curl request from the `sleep-client` to `echo-server`:
```bash
kubectl exec -n apps-ambient deploy/sleep-client -- curl -s http://echo-server/
```

Check `ztunnel` access logs to confirm traffic was encrypted over HBONE (`15008`):
```bash
kubectl logs -n istio-system -l app=ztunnel --tail=20
```

### 4. Verify Waypoint Proxy (L7 Layer)
```bash
kubectl get gateway -n apps-ambient
kubectl get pods -n apps-ambient -l gateway.networking.k8s.io/gateway-name=namespace-waypoint
```
