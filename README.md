# harkesh-k8s

Manifests Kubernetes pour le homelab. Les secrets sont gérés via **1Password Connect Operator** et les déploiements via **ArgoCD** (GitOps). Les images sont surveillées et mises à jour automatiquement par **Renovate**.

## Structure

```
/
├── _archived/                     # Apps hors service (manifests conservés pour référence)
│   ├── altertrack/                #   AlterTrack (archivé 2026-06-27)
│   ├── etudes/                    #   PageBleue (archivé 2026-06-27)
│   └── cloudflare-tunnel-routes.md #  Routes tunnel supprimées
├── argocd/                        # App-of-Apps : root Application + ApplicationSet
│   ├── applicationset.yaml        # ApplicationSet cluster-apps (1 dossier = 1 Application)
│   ├── appproject-default.yaml    # AppProject default (sourceRepos)
│   ├── argocd-ingress.yaml        # Ingress ArgoCD
│   ├── betterstack-collector.yaml # App Helm BetterStack collector
│   ├── dcgm-exporter.yaml         # App Helm DCGM exporter (GPU)
│   ├── helm-repositories.yaml     # Repos Helm déclarés (Secrets)
│   ├── k8s-device-plugin.yaml     # App Helm NVIDIA device plugin (GPU)
│   ├── kube-prometheus-stack.yaml # App Helm kube-prometheus-stack (Grafana/Prometheus)
│   ├── n8n.yaml                   # App Helm n8n (8gears/n8n-helm-chart)
│   └── root-app.yaml              # Bootstrap : root Application (lit argocd/)
├── axtazer-me/
│   └── axtazer-me.yaml            # Site axtazer.me
├── bots/
│   ├── axtazia.yaml               # Bot Discord/Twitch Axtazia
│   ├── warframe-bot.yaml
│   ├── warframe-knowledge-sync.yaml
│   └── warframe-postgres.yaml
├── flo-pro/
│   ├── dev_flo-pro.yaml           # Dev Flo-Pro web
│   └── web_flo-pro.yaml           # Flo-Pro web
├── infra/
│   └── cloudflared/
│       └── cloudflared.yaml       # Cloudflare Tunnel (kube-system, appliqué manuellement)
├── jellyfin/
│   └── jellyfin.yaml              # Jellyfin
├── media-stack/                   # Stack *arr (namespace media)
│   ├── secrets.yaml               #   OnePasswordItem mullvad-credentials
│   ├── prowlarr.yaml              #   Indexers — prowlarr.axtazer.me
│   ├── radarr.yaml                #   Films — radarr.axtazer.me
│   ├── sonarr.yaml                #   Séries + anime — sonarr.axtazer.me
│   ├── qbittorrent.yaml           #   Torrent + Gluetun VPN — qbit.axtazer.me
│   └── jellyseerr.yaml            #   Demandes médias — jellyseerr.axtazer.me
├── monitoring/
│   ├── betterstack-collector-onepassword.yaml
│   └── kube-prometheus-stack-onepassword.yaml
├── n8n/
│   ├── 1password-secrets.yaml     # OnePasswordItem n8n-secrets + n8n-db-secrets
│   ├── helm-values.yaml           # Values chart 8gears/n8n-helm-chart (n8n)
│   ├── namespace.yaml
│   ├── networkpolicy.yaml         # NetworkPolicies (default-deny + allow ciblés)
│   └── postgres.yaml              # StatefulSet PostgreSQL 16 + Service (DB n8n)
├── nextcloud/
│   └── nextcloud.yaml             # Nextcloud + MariaDB + Redis
├── ollama/
│   └── ollama.yaml                # Ollama
├── pelican/
│   ├── panel.yaml                 # Pelican Panel + Services + Ingress
│   ├── wings-ingress.yaml         # Ingress Wings
│   └── wings.yaml                 # Wings (daemon Pelican)
├── shlink/
│   └── shlink.yaml                # Shlink URL shortener + Web client + PostgreSQL
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
Cilium Gateway API  (shared-gateway, kube-system)
    ↓  HTTPRoute par app
Services K8s
```

- **Cloudflare Tunnel** : géré en GitOps via `ingressClassName: cloudflare-tunnel`
- **Cilium Gateway API** : remplace ingress-nginx, préserve les IPs clients nativement
- **Cloudflare Access** : configuré uniquement dans le dashboard Zero Trust (pas de manifest K8s)
- Chaque app a un fichier `routes.yaml` avec son `HTTPRoute` + `Ingress` cloudflare-tunnel

## Réinstallation complète

### 1. Cilium (CNI + Gateway API)

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
  --set kubeProxyReplacement=true
```

> ⚠️ Les CRDs Gateway API doivent être installées **avant** d'activer Cilium Gateway API.
> ArgoCD s'en charge via l'app `gateway-api-crds` (sync-wave -1).
> En bootstrap manuel : `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml`

### 2. 1Password Connect Server

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
  (`axtazer-me`, `bots`, `flo-pro`, `jellyfin`, `media-stack`, `monitoring`, `nextcloud`, `ollama`, `pelican`, `shlink`) ;
- les Applications Helm dédiées : `argocd/n8n.yaml`, `argocd/kube-prometheus-stack.yaml`, `argocd/dcgm-exporter.yaml`,
  `argocd/betterstack-collector.yaml`, `argocd/k8s-device-plugin.yaml`.

`infra/cloudflared` n'est **pas** couvert par l'ApplicationSet (hors-liste) et doit être créé manuellement :

```bash
argocd app create cloudflared --repo git@github.com:Axtazer/harkesh-k8s.git --path infra/cloudflared --dest-server https://kubernetes.default.svc --dest-namespace kube-system --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
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

| Item 1Password        | Secret K8s              | Namespace     |
|-----------------------|-------------------------|---------------|
| `nextcloud-db`        | `nextcloud-db-secret`   | `nextcloud`   |
| `axtazia-bot`         | `axtazia-secrets`       | `bots`        |
| `cloudflared`         | `cloudflared-token`     | `cloudflared` |
| `cloudflare-tunnel-controller` | `cloudflare-tunnel-controller` | `cloudflare-tunnel-ingress-controller` |
| `shlink`              | `shlink-secrets`        | `shlink`      |
| `shlink-db`           | `shlink-db-secret`      | `shlink`      |
| `axtazer-me`          | `axtazer-secrets`       | `axtazer-me`  |
| `grafana-admin`       | `grafana-admin`         | `monitoring`  |
| `n8n`                 | `n8n-secrets`           | `n8n`         |
| `n8n-db`              | `n8n-db-secrets`        | `n8n`         |
| `mullvad-credentials` | `mullvad-credentials`   | `media`       |

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
| Grafana | `monitoring` | `https://grafana.castaldo.fr` | — | — | config via Helm values kube-prometheus-stack, hors repo |
| Pelican Panel | `pelican` | `https://panel.axtazer.me` | `http://pelican-panel-svc.pelican.svc.cluster.local:80` | `v1.0.0-beta34` | URL corrigée (anciennement `panel.castaldo.fr`) |
| Wings | `wings` | `https://node01.axtazer.me` | `http://wings-svc.wings.svc.cluster.local:8443` | `latest` (digest pinné) | URL corrigée (anciennement `wings.castaldo.fr`, cf. commit c4e486e) |
| Nextcloud | `nextcloud` | `https://nas.castaldo.fr` | `http://nextcloud.nextcloud.svc.cluster.local:80` | `apache` (digest pinné) | |
| MariaDB (nextcloud) | `nextcloud` | interne uniquement | `http://mariadb.nextcloud.svc.cluster.local:3306` | `11` | |
| Redis (nextcloud) | `nextcloud` | interne uniquement | `http://redis.nextcloud.svc.cluster.local:6379` | `alpine` | |
| Jellyfin | `media` | `https://stream.axtazer.me` | `http://jellyfin.media.svc.cluster.local:8096` | `10.11.11` | |
| Prowlarr | `media` | `https://prowlarr.axtazer.me` | `http://prowlarr.media.svc.cluster.local:9696` | `latest` (linuxserver) | |
| Radarr | `media` | `https://radarr.axtazer.me` | `http://radarr.media.svc.cluster.local:7878` | `latest` (linuxserver) | |
| Sonarr | `media` | `https://sonarr.axtazer.me` | `http://sonarr.media.svc.cluster.local:8989` | `latest` (linuxserver) | |
| qBittorrent + Gluetun | `media` | `https://qbit.axtazer.me` | `http://qbittorrent.media.svc.cluster.local:8080` | `latest` (linuxserver + gluetun) | VPN Mullvad WireGuard en sidecar |
| Jellyseerr | `media` | `https://jellyseerr.axtazer.me` | `http://jellyseerr.media.svc.cluster.local:5055` | `latest` (fallenbagel) | |
| **[archivé 2026-06-27]** AlterTrack | — | `https://altertrack.castaldo.fr` | — | — | Manifests dans `_archived/altertrack/` |
| **[archivé 2026-06-27]** PageBleue | — | `https://pagebleue.castaldo.fr` | — | — | Manifests dans `_archived/etudes/` |
| **[archivé 2026-06-27]** Delivreou | — | `https://delivreou.castaldo.fr` | — | — | Jamais de manifest dans le repo |
| Ollama | `ollama` | interne uniquement | `http://ollama.ollama.svc.cluster.local:11434` | `0.9.0` | |
| Axtazia Bot | `bots` | — (bot Discord/Twitch, pas de service exposé) | — | `latest` (digest pinné) | |
| Warframe Bot | `bots` | — (bot Discord, pas de service exposé) | — | digest pinné (`90375df`) | |
| PostgreSQL (warframe) | `bots` | interne uniquement | `http://warframe-postgres.bots.svc.cluster.local:5432` | `18-alpine` | |
| cloudflare-tunnel-ingress-controller | `cloudflare-tunnel-ingress-controller` | — | — | `0.0.23` | gère routes Cloudflare via Ingress K8s |
| Delivre Où? | `etudes` | `https://delivreou.castaldo.fr` | — | — | **[retiré - 2026-06-14]** : aucun manifest correspondant dans le repo actuel |
| n8n | `n8n` | `https://n8n.castaldo.fr` | `http://n8n.n8n.svc.cluster.local:5678` | `1.122.4` | nouveau |
| PostgreSQL (n8n) | `n8n` | interne uniquement | `http://postgres.n8n.svc.cluster.local:5432` | `16` | nouveau |

## Renovate

Les images Docker sont suivies et mises à jour automatiquement via Renovate (config dans `renovate.json`).

| Image | Stratégie |
|---|---|
| `nextcloud` + `mariadb` + `redis` | Manuel — review obligatoire |
| `ghcr.io/pelican-dev/*` | Automerge digest/patch/minor |
| `cloudflare/cloudflared` | Automerge digest/patch/minor |
| `gcr.io/cadvisor/cadvisor` | **[retiré - 2026-06-14]** |
| `ghcr.io/axtazer/axtazia` | Automerge digest |
| `ghcr.io/axtazer/delivreou` | **[archivé - 2026-06-27]** |
| `ghcr.io/axtazer/flo-pro` | Automerge digest |
| `ghcr.io/axtazer/axtazer-me` | Non suivi (package privé) |
| `ghcr.io/shlinkio/shlink` | Automerge digest/patch/minor |
| `ghcr.io/shlinkio/shlink-web-client` | Automerge digest/patch/minor |
| `postgres` (shlink, n8n) | Major bloqué — migrations irréversibles |
| `n8nio/n8n` | Automerge digest/patch/minor — major manuel (review `Axtazer`) |
| Toutes les majors | Manuel — review obligatoire |
