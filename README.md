# harkesh-k8s

Manifests Kubernetes pour le homelab. Les secrets sont gérés via **1Password Connect Operator** et les déploiements via **ArgoCD** (GitOps). Les images sont surveillées et mises à jour automatiquement par **Renovate**.

## Structure

```
/
├── argocd/
│   └── argocd.yaml               # Ingress ArgoCD
├── axtazer-me/
│   └── axtazer-me.yaml           # Site axtazer.me
├── bots/
│   └── axtazia.yaml              # Bot Discord/Twitch Axtazia
├── cloudflared/
│   └── cloudflared.yaml          # Cloudflare Tunnel (kube-system)
├── etudes/
│   ├── delivreou/
│   │   └── delivreou-full.yaml   # Délivre Où ? (app + MariaDB)
│   └── PageBleue/
│       └── pagebleue.yaml        # PageBleue
├── flo-pro/
│   ├── web_flo-pro.yaml          # Flo-Pro web
│   └── dev_flo-pro.yaml          # Dev Flo-Pro web
├── monitoring/
│   └── cadvisor.yaml             # cAdvisor (DaemonSet)
├── pelican/
│   └── panel.yaml                # Pelican Panel + Services + Ingress
├── shlink/
│   └── shlink.yaml               # Shlink URL shortener + Web client + PostgreSQL
├── storageServices/
│   └── nextcloud.yaml            # Nextcloud + MariaDB + Redis
├── wings/
│   ├── wings.yaml                # Wings (daemon Pelican)
│   └── wings-ingress.yaml        # Ingress Wings
└── renovate.json                 # Config Renovate (image tracking)
```

## Prérequis

- Kubernetes (kubeadm)
- `helm`, `kubectl`, `kubectl krew`, `kubectl neat`

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

### 4. ArgoCD (GitOps)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace
```

CLI et connexion repo :

```bash
curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
argocd login argocd.castaldo.fr --username admin --grpc-web
argocd repo add git@github.com:Axtazer/harkesh-k8s.git --ssh-private-key-path ~/.ssh/id_ed25519 --grpc-web
```

Création des apps :

```bash
argocd app create nextcloud    --repo git@github.com:Axtazer/harkesh-k8s.git --path storageServices    --dest-server https://kubernetes.default.svc --dest-namespace nextcloud   --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
argocd app create pelican      --repo git@github.com:Axtazer/harkesh-k8s.git --path pelican            --dest-server https://kubernetes.default.svc --dest-namespace pelican      --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
argocd app create wings        --repo git@github.com:Axtazer/harkesh-k8s.git --path wings              --dest-server https://kubernetes.default.svc --dest-namespace wings        --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
argocd app create cloudflared  --repo git@github.com:Axtazer/harkesh-k8s.git --path cloudflared        --dest-server https://kubernetes.default.svc --dest-namespace kube-system  --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
argocd app create axtazia      --repo git@github.com:Axtazer/harkesh-k8s.git --path bots               --dest-server https://kubernetes.default.svc --dest-namespace bots         --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
argocd app create monitoring   --repo git@github.com:Axtazer/harkesh-k8s.git --path monitoring         --dest-server https://kubernetes.default.svc --dest-namespace monitoring   --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
argocd app create delivreou    --repo git@github.com:Axtazer/harkesh-k8s.git --path etudes/delivreou   --dest-server https://kubernetes.default.svc --dest-namespace delivreou    --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
argocd app create pagebleue    --repo git@github.com:Axtazer/harkesh-k8s.git --path etudes/PageBleue   --dest-server https://kubernetes.default.svc --dest-namespace etudes       --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
argocd app create flo-pro      --repo git@github.com:Axtazer/harkesh-k8s.git --path flo-pro            --dest-server https://kubernetes.default.svc --dest-namespace flo-pro     --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
argocd app create shlink       --repo git@github.com:Axtazer/harkesh-k8s.git --path shlink             --dest-server https://kubernetes.default.svc --dest-namespace shlink      --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
argocd app create axtazer-me   --repo git@github.com:Axtazer/harkesh-k8s.git --path axtazer-me         --dest-server https://kubernetes.default.svc --dest-namespace axtazer-me  --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
```

### 5. Monitoring (kube-prometheus-stack)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

### 6. DCGM Exporter (GPU)

```bash
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm install dcgm-exporter gpu-helm-charts/dcgm-exporter \
  -n monitoring \
  --set service.ipFamilies[0]=IPv4 \
  --set service.ipFamilyPolicy=SingleStack \
  --set serviceMonitor.enabled=true
```

## Secrets

Tous les secrets sont dans le vault `k8s-home` sur 1Password et injectés automatiquement par le **1Password Connect Operator** via les `OnePasswordItem` définis dans chaque manifest.

| Item 1Password   | Secret K8s            | Namespace     |
|------------------|-----------------------|---------------|
| `nextcloud-db`   | `nextcloud-db-secret` | `nextcloud`   |
| `axtazia-bot`    | `axtazia-secrets`     | `bots`        |
| `cloudflared`    | `cloudflared-token`   | `kube-system` |
| `delivreou`      | `delivreou-env`       | `delivreou`   |
| `pagebleue-env`  | `pagebleue-env`       | `etudes`      |
| `shlink`         | `shlink-secrets`      | `shlink`      |
| `shlink-db`      | `shlink-db-secret`    | `shlink`      |
| `axtazer-me`     | `axtazer-secrets`     | `axtazer-me`  |
| `grafana-admin`  | `grafana-admin`       | `monitoring`  |

## Secrets gérés manuellement

Certains secrets ne peuvent pas être gérés via 1Password Connect Operator
car celui-ci ne supporte pas le type `kubernetes.io/dockerconfigjson` (bug #95).

### ghcr-secret

À recréer manuellement après chaque réinstallation dans chaque namespace qui utilise des images GHCR privées :

```bash
for ns in bots axtazer-me etudes flo-pro altertrack; do
  kubectl create secret docker-registry ghcr-secret \
    --docker-server=ghcr.io \
    --docker-username=Axtazer \
    --docker-password=GHCR_TOKEN \
    -n $ns
done
```

Le token GHCR est stocké dans 1Password → vault `k8s-home` → item `ghcr-token`.

## Domaines

Tous les domaines passent par le **Cloudflare Tunnel** — aucun port exposé sur le routeur.

| Domaine                  | Service              |
|--------------------------|----------------------|
| `axtazer.me`             | axtazer.me           |
| `go.axtazer.me`          | Shlink (raccourcisseur) |
| `shlink.axtazer.me`      | Shlink Web Client    |
| `castaldo.fr`            | Flo-pro              |
| `dev-pro.castaldo.fr`    | Dev Flo-pro          |
| `argocd.castaldo.fr`     | ArgoCD               |
| `grafana.castaldo.fr`    | Grafana              |
| `panel.castaldo.fr`      | Pelican Panel        |
| `wings.castaldo.fr`      | Wings                |
| `nas.castaldo.fr`        | Nextcloud            |
| `delivreou.castaldo.fr`  | Delivre Où?          |

## Renovate

Les images Docker sont suivies et mises à jour automatiquement via Renovate (config dans `renovate.json`).

| Image | Stratégie |
|---|---|
| `nextcloud` + `mariadb` + `redis` | Manuel — review obligatoire |
| `ghcr.io/pelican-dev/*` | Automerge digest/patch/minor |
| `cloudflare/cloudflared` | Automerge digest/patch/minor |
| `gcr.io/cadvisor/cadvisor` | Automerge digest/patch |
| `ghcr.io/axtazer/axtazia` | Automerge digest |
| `ghcr.io/axtazer/delivreou` | Automerge digest |
| `ghcr.io/axtazer/flo-pro` | Automerge digest |
| `ghcr.io/axtazer/axtazer-me` | Non suivi (package privé) |
| `ghcr.io/shlinkio/shlink` | Automerge digest/patch/minor |
| `ghcr.io/shlinkio/shlink-web-client` | Automerge digest/patch/minor |
| `postgres` (shlink) | Major bloqué — migrations irréversibles |
| Toutes les majors | Manuel — review obligatoire |
