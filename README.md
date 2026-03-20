# harkesh-k8s

Manifests Kubernetes pour le homelab. Les secrets sont gérés via 1Password Connect.

## Structure

```
/srv/kubernetes/
├── bots/
│   └── axtazia.yaml          # Bot Discord Axtazia
├── monitoring/
│   └── cadvisor.yaml         # cAdvisor
├── pelican/
│   ├── panel.yaml            # Pelican Panel
│   └── importer.yaml
├── storageServices/
│   └── nextcloud.yaml        # Nextcloud + MariaDB + Redis
├── wings/
│   ├── wings.yaml            # Wings (Pterodactyl)
│   └── wings-ingress.yaml
└── cloudflared.yaml          # Cloudflare Tunnel
```

## Prérequis

- Kubernetes (kubeadm)
- Helm
- kubectl + krew + neat

## Réinstallation complète

### 1. Cilium (CNI)

```bash
helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium --version 1.18.5 \
  -n kube-system \
  --set cluster.name=kubernetes \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set operator.replicas=1 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.relay.tls.enabled=false \
  --set hubble.relay.tls.client.enabled=false \
  --set hubble.tls.enabled=false \
  --set hubble.ui.enabled=true \
  --set hostFirewall.enabled=false \
  --set hostFirewall.devices[0]=enp34s0
```

### 2. Ingress-nginx

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
```

### 3. 1Password Connect Server

Récupérer `1password-credentials.json` et le token depuis 1Password → Intégrations → Connect Servers.

```bash
helm repo add 1password https://1password.github.io/connect-helm-charts
helm install connect 1password/connect \
  -n 1password --create-namespace \
  --set connect.credentials_base64=$(base64 -w0 /tmp/1password-credentials.json) \
  --set operator.create=true \
  --set operator.token.value="TOKEN_ICI"

rm /tmp/1password-credentials.json
```

### 4. Monitoring (kube-prometheus-stack)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

### 5. DCGM Exporter (GPU)

```bash
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm install dcgm-exporter gpu-helm-charts/dcgm-exporter \
  -n monitoring \
  --set service.ipFamilies[0]=IPv4 \
  --set service.ipFamilyPolicy=SingleStack \
  --set serviceMonitor.enabled=true
```

### 6. Appliquer les manifests

```bash
kubectl apply -f /srv/kubernetes/cloudflared.yaml
kubectl apply -f /srv/kubernetes/storageServices/nextcloud.yaml
kubectl apply -f /srv/kubernetes/bots/axtazia.yaml
kubectl apply -f /srv/kubernetes/pelican/panel.yaml
kubectl apply -f /srv/kubernetes/pelican/importer.yaml
kubectl apply -f /srv/kubernetes/wings/wings.yaml
kubectl apply -f /srv/kubernetes/wings/wings-ingress.yaml
kubectl apply -f /srv/kubernetes/monitoring/cadvisor.yaml
```

## Secrets

Tous les secrets sont dans le vault `k8s-home` sur 1Password :

| Item 1Password | Secret K8s | Namespace |
|---|---|---|
| `nextcloud-db` | `nextcloud-db-secret` | `nextcloud` |
| `axtazia-bot` | `axtazia-secrets` | `default` |

Les secrets sont créés automatiquement par le 1Password Connect Operator via les `OnePasswordItem` définis dans chaque manifest.

## Domaines

| Domaine | Service |
|---|---|
| `nas.castaldo.fr` | Nextcloud |
| `panel.castaldo.fr` | Pelican Panel |
| `wings.castaldo.fr` | Wings |

Tous les domaines passent par le **Cloudflare Tunnel** — aucun port exposé sur le routeur.

### 6. ArgoCD (GitOps)
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace
```

Puis installe le CLI et connecte le repo :
```bash
curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
argocd login argocd.castaldo.fr --username admin --grpc-web
argocd repo add git@github.com:Axtazer/harkesh-k8s.git --ssh-private-key-path ~/.ssh/id_ed25519 --grpc-web
```

Crée les apps :
```bash
argocd app create nextcloud --repo git@github.com:Axtazer/harkesh-k8s.git --path storageServices --dest-server https://kubernetes.default.svc --dest-namespace nextcloud --sync-policy automated --revision master --grpc-web
argocd app create axtazia --repo git@github.com:Axtazer/harkesh-k8s.git --path bots --dest-server https://kubernetes.default.svc --dest-namespace default --sync-policy automated --revision master --grpc-web
argocd app create wings --repo git@github.com:Axtazer/harkesh-k8s.git --path wings --dest-server https://kubernetes.default.svc --dest-namespace wings --sync-policy automated --revision master --grpc-web
argocd app create pelican --repo git@github.com:Axtazer/harkesh-k8s.git --path pelican --dest-server https://kubernetes.default.svc --dest-namespace pelican --sync-policy automated --revision master --grpc-web
argocd app create cloudflared --repo git@github.com:Axtazer/harkesh-k8s.git --path cloudflared --dest-server https://kubernetes.default.svc --dest-namespace kube-system --sync-policy automated --revision master --grpc-web
argocd app create monitoring --repo git@github.com:Axtazer/harkesh-k8s.git --path monitoring --dest-server https://kubernetes.default.svc --dest-namespace monitoring --sync-policy automated --revision master --grpc-web
```
