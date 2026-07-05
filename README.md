# harkesh-k8s

Manifests Kubernetes pour le homelab. Les secrets sont gérés via **1Password Connect Operator** et les déploiements via **ArgoCD** (GitOps). Les images sont surveillées et mises à jour automatiquement par **Renovate**.

## Structure

```
/
├── _archived/                     # Apps hors service (manifests conservés pour référence)
│   ├── altertrack/                #   AlterTrack (archivé 2026-06-27)
│   ├── betterstack-collector/     #   BetterStack collector (archivé 2026-07-05)
│   └── etudes/                    #   PageBleue (archivé 2026-06-27)
├── argocd/                        # App-of-Apps : root Application + ApplicationSet
│   ├── applicationset.yaml        # ApplicationSet cluster-apps (1 dossier = 1 Application)
│   ├── appproject-default.yaml    # AppProject default (sourceRepos)
│   ├── argocd-ingress.yaml        # Ingress + HTTPRoute ArgoCD
│   ├── cilium.yaml                # App Helm Cilium CNI (sync-wave -2)
│   ├── cilium-gateway.yaml        # App infra/cilium/ : Gateway + LB pool (sync-wave 0)
│   ├── cloudflare-tunnel-controller.yaml # App Helm tunnel controller (sync-wave 1)
│   ├── dcgm-exporter.yaml         # App Helm DCGM exporter (GPU)
│   ├── helm-repositories.yaml     # Repos Helm déclarés (Secrets)
│   ├── k8s-device-plugin.yaml     # App Helm NVIDIA device plugin (GPU)
│   ├── kube-prometheus-stack.yaml # App Helm kube-prometheus-stack (Grafana/Prometheus)
│   ├── n8n.yaml                   # App Helm n8n (8gears/n8n-helm-chart)
│   ├── namespace.yaml             # Namespace argocd (label shared-gateway-access)
│   └── root-app.yaml              # Bootstrap : root Application (lit argocd/)
├── axtazer-me/
│   ├── axtazer-me.yaml            # Site axtazer.me
│   └── routes.yaml                # HTTPRoute + Ingress cloudflare-tunnel
├── bots/
│   ├── axtazia.yaml               # Bot Discord/Twitch Axtazia + Service webhook Twitch
│   └── routes.yaml                # HTTPRoute webhook /webhook/twitch
├── flo-pro/
│   ├── dev_flo-pro.yaml           # Dev Flo-Pro web
│   ├── namespace.yaml             # Namespace flo-pro (label shared-gateway-access)
│   ├── routes.yaml                # HTTPRoute + Ingress cloudflare-tunnel
│   └── web_flo-pro.yaml           # Flo-Pro web
├── infra/
│   ├── cilium/
│   │   ├── gateway-api-crds.yaml  # App ArgoCD Gateway API CRDs (sync-wave -1)
│   │   ├── gateway.yaml           # shared-gateway (kube-system, Cilium Gateway API)
│   │   ├── lb-pool.yaml           # CiliumLoadBalancerIPPool 192.168.1.203/32 + L2 policy
│   │   └── values.yaml            # Values Helm Cilium (gatewayAPI, l2announcements…)
│   └── cloudflare-tunnel-controller/
│       ├── README.md
│       ├── secret.yaml            # OnePasswordItem cloudflare-tunnel-controller
│       └── values.yaml            # Values Helm tunnel controller
├── jellyfin/
│   ├── jellyfin.yaml              # Jellyfin
│   └── routes.yaml                # HTTPRoute + Ingress cloudflare-tunnel
├── media-stack/                   # Stack *arr (namespace media)
│   ├── secrets.yaml               #   OnePasswordItem mullvad-credentials
│   ├── prowlarr.yaml              #   Indexers — prowlarr.axtazer.me
│   ├── radarr.yaml                #   Films — radarr.axtazer.me
│   ├── sonarr.yaml                #   Séries + anime — sonarr.axtazer.me
│   ├── qbittorrent.yaml           #   Torrent + Gluetun VPN — qbit.axtazer.me
│   ├── jellyseerr.yaml            #   Seerr (fork Jellyseerr) — jellyseerr.axtazer.me
│   └── routes.yaml                #   HTTPRoutes + Ingress cloudflare-tunnel (toute la stack)
├── monitoring/
│   ├── ENDPOINTS.md                # Endpoints à monitorer (externe)
│   ├── kube-prometheus-stack-onepassword.yaml
│   ├── namespace.yaml             # Namespace monitoring (label shared-gateway-access)
│   └── routes.yaml                # HTTPRoute Grafana + Ingress cloudflare-tunnel
├── n8n/
│   ├── 1password-secrets.yaml     # OnePasswordItem n8n-secrets + n8n-db-secrets
│   ├── helm-values.yaml           # Values chart 8gears/n8n-helm-chart (n8n)
│   ├── namespace.yaml             # Namespace n8n (label shared-gateway-access)
│   ├── networkpolicy.yaml         # NetworkPolicies (default-deny + allow ciblés)
│   ├── postgres.yaml              # StatefulSet PostgreSQL 16 + Service (DB n8n)
│   └── routes.yaml                # HTTPRoute + Ingress cloudflare-tunnel
├── authentik/
│   ├── authentik.yaml             # Authentik SSO (server + worker + PostgreSQL)
│   └── routes.yaml                # Ingress cloudflare-tunnel → auth.axtazer.me
├── nextcloud/
│   ├── nextcloud.yaml             # Nextcloud + MariaDB + Redis
│   └── routes.yaml                # HTTPRoute + Ingress cloudflare-tunnel
├── ntfy/
│   ├── ntfy.yaml                   # ntfy (serveur notifications push) + PV/PVC persistant
│   └── routes.yaml                # HTTPRoute + Ingress cloudflare-tunnel
├── pelican/
│   ├── panel.yaml                 # Pelican Panel + Services
│   ├── routes.yaml                # HTTPRoutes panel + wings + Ingress cloudflare-tunnel
│   └── wings.yaml                 # Wings (daemon Pelican)
├── shlink/
│   ├── shlink.yaml                # Shlink URL shortener + Web client + PostgreSQL
│   └── routes.yaml                # HTTPRoutes go + shlink-web + Ingress cloudflare-tunnel
└── renovate.json                  # Config Renovate (image tracking)
```

## Prérequis

- Kubernetes (kubeadm)
- `helm`, `kubectl`, `kubectl krew`, `kubectl neat`

## Architecture réseau

```
Cloudflare Edge
    ↓
cloudflare-tunnel-ingress-controller  (gère routes + DNS via Ingress K8s)
    ↓  CF-Connecting-IP header (vraie IP client)
Cilium Gateway API  (shared-gateway @ 192.168.1.203, kube-system)
    ↓  HTTPRoute par app
Services K8s
```

- **Cloudflare Tunnel** : géré en GitOps via `ingressClassName: cloudflare-tunnel`
- **Cilium Gateway API** : remplace ingress-nginx, préserve les IPs clients nativement
- **L2 IPAM** : `CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` sur `enp34s0` → IP `192.168.1.203`
- **Cloudflare Access** : configuré uniquement dans le dashboard Zero Trust (pas de manifest K8s)
- Chaque app a un fichier `routes.yaml` avec son `HTTPRoute` + `Ingress` cloudflare-tunnel

## Réinstallation complète

### 1. Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

### 2. Cilium (CNI + Gateway API)

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
  --set hostFirewall.devices[0]=enp34s0 \
  --set gatewayAPI.enabled=true \
  --set kubeProxyReplacement=true \
  --set l2announcements.enabled=true
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

Bootstrap de l'app-of-apps `root` (lit le dossier `argocd/`) :

```bash
argocd app create root --repo git@github.com:Axtazer/harkesh-k8s.git --path argocd --dest-server https://kubernetes.default.svc --dest-namespace argocd --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
```

`root` déploie ensuite automatiquement :
- l'ApplicationSet `cluster-apps` (`argocd/applicationset.yaml`), qui crée une Application par dossier listé
  (`authentik`, `axtazer-me`, `bots`, `flo-pro`, `jellyfin`, `media-stack`, `monitoring`, `nextcloud`, `ntfy`, `pelican`, `shlink`) ;
- les Applications Helm dédiées : `argocd/n8n.yaml`, `argocd/kube-prometheus-stack.yaml`, `argocd/dcgm-exporter.yaml`,
  `argocd/k8s-device-plugin.yaml` ;
- les apps infra : `argocd/cilium.yaml`, `argocd/cilium-gateway.yaml`, `argocd/cloudflare-tunnel-controller.yaml`.

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

| Item 1Password | Secret K8s | Namespace |
|---|---|---|
| `nextcloud-db` | `nextcloud-db-secret` | `nextcloud` |
| `axtazia-bot` | `axtazia-secrets` | `bots` |
| `cloudflare-tunnel-controller` | `cloudflare-tunnel-controller` | `cloudflare-tunnel-ingress-controller` |
| `shlink` | `shlink-secrets` | `shlink` |
| `shlink-db` | `shlink-db-secret` | `shlink` |
| `axtazer-me` | `axtazer-secrets` | `axtazer-me` |
| `grafana-admin` | `grafana-admin` | `monitoring` |
| `n8n` | `n8n-secrets` | `n8n` |
| `n8n-db` | `n8n-db-secrets` | `n8n` |
| `mullvad-credentials` | `mullvad-credentials` | `media` |
| `authentik` | `authentik-secret` | `authentik` |

## Secrets gérés manuellement

Certains secrets ne peuvent pas être gérés via 1Password Connect Operator
car celui-ci ne supporte pas le type `kubernetes.io/dockerconfigjson` (bug #95).

### ghcr-secret

À recréer manuellement après chaque réinstallation dans chaque namespace qui utilise des images GHCR privées :

```bash
for ns in bots axtazer-me flo-pro; do
  kubectl create secret docker-registry ghcr-secret \
    --docker-server=ghcr.io \
    --docker-username=Axtazer \
    --docker-password=GHCR_TOKEN \
    -n $ns
done
```

Le token GHCR est stocké dans 1Password → vault `k8s-home` → item `ghcr-token`.

## Services

Tous les accès externes passent par le **Cloudflare Tunnel** — aucun port exposé sur le routeur.
`Accès interne K8s` = adresse joignable depuis un autre pod du cluster (`<service>.<namespace>.svc.cluster.local:<port>`).

| Service | Namespace | Accès externe | Accès interne K8s | Version | Notes |
|---|---|---|---|---|---|
| axtazer.me | `axtazer-me` | `https://axtazer.me` | `http://axtazer-me.axtazer-me.svc.cluster.local:80` | digest pinné | |
| Shlink (raccourcisseur) | `shlink` | `https://go.axtazer.me` | `http://shlink.shlink.svc.cluster.local:80` | `stable` (digest pinné) | |
| Shlink Web Client | `shlink` | `https://shlink.axtazer.me` | `http://shlink-web.shlink.svc.cluster.local:80` | `stable` (digest pinné) | |
| PostgreSQL (shlink) | `shlink` | interne uniquement | `http://postgres.shlink.svc.cluster.local:5432` | `17-alpine` | |
| Flo-pro | `flo-pro` | `https://castaldo.fr` | `http://flo-pro.flo-pro.svc.cluster.local:80` | `main` (digest pinné) | |
| Dev Flo-pro | `flo-pro` | `https://dev-pro.castaldo.fr` | `http://dev-flo-pro.flo-pro.svc.cluster.local:81` | `dev` (digest pinné) | |
| ArgoCD | `argocd` | `https://argocd.castaldo.fr` | — | — | |
| Grafana | `monitoring` | `https://grafana.castaldo.fr` | — | — | config via Helm values kube-prometheus-stack |
| Pelican Panel | `pelican` | `https://panel.axtazer.me` | `http://pelican-panel-svc.pelican.svc.cluster.local:80` | `v1.0.0-beta34` | |
| Wings | `wings` | `https://node01.axtazer.me` | `http://wings-svc.wings.svc.cluster.local:8443` | `latest` (digest pinné) | |
| Nextcloud | `nextcloud` | `https://nas.castaldo.fr` | `http://nextcloud.nextcloud.svc.cluster.local:80` | `apache` (digest pinné) | |
| MariaDB (nextcloud) | `nextcloud` | interne uniquement | `http://mariadb.nextcloud.svc.cluster.local:3306` | `11` | |
| Redis (nextcloud) | `nextcloud` | interne uniquement | `http://redis.nextcloud.svc.cluster.local:6379` | `alpine` | |
| Jellyfin | `media` | `https://stream.axtazer.me` | `http://jellyfin.media.svc.cluster.local:8096` | `10.11.11` | Proxies connus : `10.0.0.0/8` |
| Prowlarr | `media` | `https://prowlarr.axtazer.me` | `http://prowlarr.media.svc.cluster.local:9696` | `latest` (linuxserver) | |
| Radarr | `media` | `https://radarr.axtazer.me` | `http://radarr.media.svc.cluster.local:7878` | `latest` (linuxserver) | |
| Sonarr | `media` | `https://sonarr.axtazer.me` | `http://sonarr.media.svc.cluster.local:8989` | `latest` (linuxserver) | |
| qBittorrent + Gluetun | `media` | `https://qbit.axtazer.me` | `http://qbittorrent.media.svc.cluster.local:8080` | `latest` (linuxserver + gluetun) | VPN Mullvad WireGuard en sidecar |
| Seerr | `media` | `https://jellyseerr.axtazer.me` | `http://jellyseerr.media.svc.cluster.local:5055` | `v3.3.0+` (seerr-team) | Fork Jellyseerr |
| n8n | `n8n` | `https://n8n.castaldo.fr` | `http://n8n.n8n.svc.cluster.local:5678` | `1.122.4+` | |
| PostgreSQL (n8n) | `n8n` | interne uniquement | `http://postgres.n8n.svc.cluster.local:5432` | `16` | |
| Axtazia Bot | `bots` | `https://axtazia.axtazer.me/webhook/twitch` | `http://axtazia-bot.bots.svc.cluster.local:3000` | `latest` (digest pinné) | Webhook Twitch EventSub sur port 3000 |
| Authentik SSO | `authentik` | `https://auth.axtazer.me` | `http://authentik-server.authentik.svc.cluster.local:9000` | `2026.5.3` | Provider SSO OIDC pour les autres apps |
| PostgreSQL (authentik) | `authentik` | interne uniquement | `http://postgresql.authentik.svc.cluster.local:5432` | `16` | |
| ntfy | `ntfy` | `https://ntfy.axtazer.me` | `http://ntfy.ntfy.svc.cluster.local:80` | `v2.25.0` (digest pinné) | Auth activée, `deny-all` par défaut |
| cloudflare-tunnel-ingress-controller | `cloudflare-tunnel-ingress-controller` | — | — | `0.0.23` | Gère routes Cloudflare via Ingress K8s |
| **[archivé 2026-06-27]** AlterTrack | — | `https://altertrack.castaldo.fr` | — | — | Manifests dans `_archived/altertrack/` |
| **[archivé 2026-06-27]** PageBleue | — | `https://pagebleue.castaldo.fr` | — | — | Manifests dans `_archived/etudes/` |
| **[archivé 2026-07-05]** BetterStack collector | — | — | — | — | Manifests dans `_archived/betterstack-collector/` |

## Renovate

Les images Docker sont suivies et mises à jour automatiquement via Renovate (config dans `renovate.json`).

| Image | Stratégie |
|---|---|
| `nextcloud` + `mariadb` + `redis` | Manuel — review obligatoire |
| `ghcr.io/pelican-dev/*` | Automerge digest/patch/minor |
| `cloudflare-tunnel-ingress-controller` (Helm) | Automerge patch/minor |
| `gcr.io/cadvisor/cadvisor` | Automerge digest/patch |
| `ghcr.io/axtazer/axtazia` | Automerge digest |
| `ghcr.io/axtazer/flo-pro` | Automerge digest |
| `ghcr.io/shlinkio/shlink` + `shlink-web-client` | Automerge digest/patch/minor |
| `ghcr.io/goauthentik/server` | Automerge digest/patch/minor — major manuel (migrations BDD) |
| `binwiederhier/ntfy` | Automerge digest/patch/minor — major manuel |
| `postgres` (shlink, n8n, authentik) | Major bloqué — migrations irréversibles |
| `n8nio/n8n` | Automerge digest/patch/minor — major manuel |
| `busybox` | Automerge digest/patch/minor |
| `jellyfin/jellyfin` | Automerge digest/patch — minor/major manuel |
| `lscr.io/linuxserver/*` + `ghcr.io/qdm12/gluetun` + Seerr | Automerge digest/patch/minor |
| Toutes les majors | Manuel — review obligatoire |
