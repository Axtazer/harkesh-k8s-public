# harkesh-k8s

Manifests Kubernetes pour le homelab. Les secrets sont gérés via **1Password Connect Operator** et les déploiements via **ArgoCD** (GitOps). Les images sont surveillées et mises à jour automatiquement par **Renovate**.

## Structure

```
/
├── _archived/                     # Apps hors service (manifests conservés pour référence)
│   ├── altertrack/                #   AlterTrack (archivé 2026-06-27)
│   ├── betterstack-collector/     #   BetterStack collector (archivé 2026-07-05)
│   ├── etudes/                    #   PageBleue (archivé 2026-06-27)
│   └── ingress-nginx/             #   ingress-nginx (archivé 2026-09-07, remplacé par Cilium Gateway API)
├── argocd/                        # App-of-Apps : root Application + ApplicationSet
│   ├── applicationset.yaml        # ApplicationSet cluster-apps (générateur list : 1 dossier = 1 Application, namespace explicite)
│   ├── appproject-default.yaml    # AppProject default (sourceRepos)
│   ├── argocd.yaml                # App Helm argo-cd : ArgoCD auto-géré (values dans infra/argocd/)
│   ├── argocd-ingress.yaml        # Ingress cloudflare-tunnel ArgoCD
│   ├── cilium.yaml                # App Helm Cilium CNI (sync-wave -2)
│   ├── cilium-gateway.yaml        # App infra/cilium/ : Gateway + LB pool (sync-wave 0)
│   ├── cloudflare-tunnel-controller.yaml # App Helm tunnel controller (sync-wave 1)
│   ├── dcgm-exporter.yaml         # App Helm DCGM exporter (GPU)
│   ├── helm-repositories.yaml     # Repos Helm déclarés (Secrets)
│   ├── k8s-device-plugin.yaml     # App Helm NVIDIA device plugin (GPU)
│   ├── local-path-provisioner.yaml # App manifests upstream : StorageClass local-path
│   ├── metrics-server.yaml        # App Helm metrics-server (kubectl top, API metrics.k8s.io)
│   ├── victoria-metrics-k8s-stack.yaml # App Helm victoria-metrics-k8s-stack (Grafana/VictoriaMetrics)
│   ├── n8n.yaml                   # App Helm n8n (8gears/n8n-helm-chart)
│   ├── namespace.yaml             # Namespace argocd (label shared-gateway-access)
│   └── root-app.yaml              # Bootstrap : root Application (lit argocd/)
├── axtazer-me/
│   ├── axtazer-me.yaml            # Site axtazer.me
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── bots/
│   ├── axtazia.yaml               # Bot Discord/Twitch Axtazia + Service webhook Twitch
│   └── routes.yaml                # Ingress cloudflare-tunnel /webhook/twitch + /oauth/callback/discord
├── flo-pro/
│   ├── dev_flo-pro.yaml           # Dev Flo-Pro web
│   ├── namespace.yaml             # Namespace flo-pro (label shared-gateway-access)
│   ├── routes.yaml                # Ingress cloudflare-tunnel
│   └── web_flo-pro.yaml           # Flo-Pro web
├── infra/
│   ├── argocd/
│   │   └── values.yaml            # Values Helm argo-cd (server.insecure) — bootstrap + argocd/argocd.yaml
│   ├── cilium/
│   │   ├── gateway-api-crds.yaml  # App ArgoCD Gateway API CRDs (sync-wave -1)
│   │   ├── gateway.yaml           # shared-gateway (kube-system, Cilium Gateway API) — aucune route active, accès de secours
│   │   ├── lb-pool.yaml           # CiliumLoadBalancerIPPool 192.168.1.203/32 (pas d'annonce L2)
│   │   └── values.yaml            # Values Helm Cilium (gatewayAPI, l2announcements…)
│   └── cloudflare-tunnel-controller/
│       ├── README.md
│       ├── secret.yaml            # OnePasswordItem cloudflare-tunnel-controller
│       └── values.yaml            # Values Helm tunnel controller
├── jellyfin/
│   ├── jellyfin.yaml              # Jellyfin
│   ├── networkpolicy.yaml         # NetworkPolicies Jellyfin (deny-all du namespace media dans media-stack/)
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── livekit/                        # SFU Element Call (appels audio/vidéo Matrix)
│   ├── livekit.yaml                #   LiveKit server + sidecar WireGuard (relais VPS)
│   ├── jwt-service.yaml            #   lk-jwt-service (auth Element Call <-> LiveKit)
│   └── routes.yaml                 #   Ingress cloudflare-tunnel livekit.axtazer.me + livekit-jwt.axtazer.me
├── matrix/
│   ├── matrix.yaml                 # Synapse + PostgreSQL + secrets 1Password + PV/PVC
│   ├── wellknown.yaml               #   /.well-known/matrix/client (découverte LiveKit)
│   ├── draupnir.yaml                #   Bot de modération (remplaçant maintenu de Mjolnir)
│   ├── maubot.yaml                  #   Maubot + plugin RSS (diffusion de flux dans les salons)
│   ├── networkpolicy.yaml           #   NetworkPolicies (deny-all + flux synapse/postgres/draupnir/maubot/well-known)
│   └── routes.yaml                 # Ingress cloudflare-tunnel (matrix.axtazer.me + maubot.axtazer.me)
├── media-stack/                   # Stack *arr (namespace media)
│   ├── secrets.yaml               #   OnePasswordItem mullvad-credentials
│   ├── prowlarr.yaml              #   Indexers — prowlarr.axtazer.me
│   ├── radarr.yaml                #   Films — radarr.axtazer.me
│   ├── sonarr.yaml                #   Séries + anime — sonarr.axtazer.me
│   ├── qbittorrent.yaml           #   Torrent + Gluetun VPN — qbit.axtazer.me
│   ├── jellyseerr.yaml            #   Seerr (fork Jellyseerr) — jellyseerr.axtazer.me
│   ├── networkpolicy.yaml         #   NetworkPolicies namespace media (deny-all + flux *arr/qBittorrent/Seerr)
│   └── routes.yaml                #   Ingress cloudflare-tunnel (toute la stack)
├── monitoring/
│   ├── ENDPOINTS.md                # Endpoints à monitorer (externe)
│   ├── VMCTL-MIGRATION.md          # Procédure migration historique Prometheus → vmsingle (vmctl)
│   ├── cadvisor.yaml               # DaemonSet cAdvisor + Service + ServiceMonitor
│   ├── grafana-onepassword.yaml    # OnePasswordItem grafana-admin + cloudflare-analytics-token
│   ├── grafana-dashboards.yaml     # ConfigMaps dashboards custom (Base, Docker (cAdvisor), Docker Containers, Cloudflare DNS Analytics)
│   ├── grafana-datasource-cloudflare.yaml # ConfigMap datasource Grafana yesoreyeram-infinity (Cloudflare GraphQL API)
│   ├── namespace.yaml             # Namespace monitoring (label shared-gateway-access)
│   └── routes.yaml                # Ingress cloudflare-tunnel Grafana
├── n8n/
│   ├── 1password-secrets.yaml     # OnePasswordItem n8n-secrets + n8n-db-secrets
│   ├── helm-values.yaml           # Values chart 8gears/n8n-helm-chart (n8n)
│   ├── namespace.yaml             # Namespace n8n (label shared-gateway-access)
│   ├── networkpolicy.yaml         # NetworkPolicies (default-deny + allow ciblés)
│   ├── postgres.yaml              # StatefulSet PostgreSQL 16 + Service (DB n8n)
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── authentik/
│   ├── authentik.yaml             # Authentik SSO (server + worker + PostgreSQL)
│   └── routes.yaml                # Ingress cloudflare-tunnel → auth.axtazer.me
├── nextcloud/
│   ├── nextcloud.yaml             # Nextcloud + MariaDB + Redis
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── ntfy/
│   ├── ntfy.yaml                   # ntfy (serveur notifications push) + PV/PVC persistant
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── pelican/
│   ├── panel.yaml                 # Pelican Panel + Services
│   ├── routes.yaml                # Ingress cloudflare-tunnel panel + wings
│   └── wings.yaml                 # Wings (daemon Pelican)
├── shlink/
│   ├── shlink.yaml                # Shlink URL shortener + Web client + PostgreSQL
│   └── routes.yaml                # Ingress cloudflare-tunnel go + shlink-web
└── renovate.json                  # Config Renovate (image tracking)
```

## Prérequis

- Kubernetes (kubeadm)
- `helm`, `kubectl`, `kubectl krew`, `kubectl neat`

## Architecture réseau

Un seul chemin d'entrée : le Cloudflare Tunnel, qui aboutit directement sur les Services K8s.

```
Internet
   ↓
Cloudflare Edge (TLS, Cloudflare Access)
   ↓
cloudflared (connecteur géré par cloudflare-tunnel-ingress-controller)
   ↓  Ingress cloudflare-tunnel → Service   (CF-Connecting-IP / X-Forwarded-For)
Services K8s
```

- **Cloudflare Tunnel** : géré en GitOps via `ingressClassName: cloudflare-tunnel` (un `routes.yaml` par app).
  Cloudflare Access (dashboard Zero Trust, pas de manifest K8s) protège tout ce chemin.
- **Cilium Gateway API** (`shared-gateway` @ `192.168.1.203`, kube-system) : conservé mais **sans aucune
  HTTPRoute**, et **sans annonce L2** (voir ci-dessous) — l'IP est allouée mais injoignable depuis le LAN.
  L'accès LAN direct n'est plus utilisé et contournait Cloudflare Access (HTTP clair, sans
  auth). Les namespaces gardent le label `shared-gateway-access: "true"` pour pouvoir rebrancher une
  route rapidement.
- **L2 IPAM** : `CiliumLoadBalancerIPPool` seul → IP `192.168.1.203` allouée au `shared-gateway`.
  La `CiliumL2AnnouncementPolicy` a été **retirée** : `192.168.1.203` est réservée côté LAN, l'annoncer
  en ARP créerait un conflit d'adresse. Personne sur le réseau ne route donc vers cette IP.
- **NetworkPolicies** : deny-all (ingress + egress) + allow ciblés dans `n8n`, `media` (stack *arr, qBittorrent,
  Jellyfin) et `matrix`. Les flux autorisés sont documentés en tête de chaque `networkpolicy.yaml`.
- **Hubble** (observabilité réseau Cilium) : la CLI n'est pas installée sur l'hôte, le binaire est dans l'agent.
  Voir ce qu'une NetworkPolicy bloque : `kubectl exec -n kube-system ds/cilium -- hubble observe -n <namespace> --verdict DROPPED --follow`
  (le message `EVENTS LOST: HUBBLE_RING_BUFFER` signale un tampon dépassé, pas un flux bloqué).
  Interface web : `kubectl port-forward -n kube-system svc/hubble-ui 12000:80` → `http://localhost:12000`.

### Accès de secours (si Cloudflare est indisponible)

Depuis le nœud (SSH), un port-forward suffit, sans rien exposer :

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:80        # http://localhost:8080
kubectl port-forward -n nextcloud svc/nextcloud 8081:80
```

Pour un accès LAN durable à une app, ajouter une `HTTPRoute` rattachée au `shared-gateway` dans son
`routes.yaml` (le namespace doit porter le label `shared-gateway-access: "true"`) :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mon-app
  namespace: mon-namespace
spec:
  parentRefs:
    - name: shared-gateway
      namespace: kube-system
  hostnames: [mon-app.axtazer.me]
  rules:
    - backendRefs:
        - name: mon-app
          port: 80
```
Puis faire pointer le nom DNS (ou `/etc/hosts`) vers l'IP du Gateway.

> ⚠️ **Ce chemin ne fonctionne pas en l'état** : il n'y a plus de `CiliumL2AnnouncementPolicy`, donc
> `192.168.1.203` n'est annoncée en ARP par personne et reste injoignable depuis le LAN. Pour le
> réactiver : allouer une IP **libre** au pool dans `infra/cilium/lb-pool.yaml` (la `.203` est réservée
> côté réseau), puis recréer la policy avec `interfaces: [eno1]`.

Attention aussi : ce chemin n'a pas Cloudflare Access devant lui — si la NetworkPolicy du namespace
n'autorise que `cloudflared`, il faut aussi autoriser l'ingress depuis le Gateway (Envoy Cilium,
`hostNetwork`).

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
  --set hostFirewall.devices[0]=eno1 \
  --set gatewayAPI.enabled=true \
  --set kubeProxyReplacement=true \
  --set l2announcements.enabled=true
```

Cilium remplace kube-proxy (`kubeProxyReplacement=true`) : le DaemonSet `kube-proxy` posé par `kubeadm init`
est inutile. À la réinstallation, `kubeadm init --skip-phases=addon/kube-proxy` ; sur le cluster existant, après
avoir vérifié `cilium status | grep KubeProxyReplacement` (→ `True`) :

```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy
# les règles iptables résiduelles disparaissent au prochain reboot du nœud
```

> `kubeadm upgrade apply` recrée l'addon kube-proxy sauf `--skip-phases=addon/kube-proxy`.

> **local-path-provisioner** (StorageClass `local-path`, utilisée par les PVC n8n, Pelican et vmsingle) n'est
> pas à installer à la main : `argocd/local-path-provisioner.yaml` applique les manifests upstream, déployé par
> `root` à l'étape 4. Ce n'est **pas** la StorageClass par défaut du cluster (les PV/PVC hostPath utilisent
> `storageClassName: ""`), ne pas la passer par défaut.

### 3. 1Password Connect Server

Récupérer `1password-credentials.json` et le token depuis 1Password → Intégrations → Connect Servers.

```bash
helm repo add 1password https://1password.github.io/connect-helm-charts
helm install connect 1password/connect \
  -n 1password --create-namespace \
  --set connect.credentials_base64=$(base64 -w0 /tmp/1password-credentials.json) \
  --set operator.create=true \
  --set operator.imageTag=<version> \
  --set operator.token.value="TOKEN_ICI"

rm /tmp/1password-credentials.json
```

> `operator.imageTag` : pinner une version (le chart met `latest` par défaut — l'installation actuelle
> tourne en `latest`, à corriger au prochain `helm upgrade`).

### 4. ArgoCD (GitOps)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  --version 9.4.15 -f infra/argocd/values.yaml   # mêmes chart/values que argocd/argocd.yaml (voir ci-dessous)
```

> ArgoCD est ensuite **auto-géré** : `argocd/argocd.yaml` (déployé par `root`) applique le même chart avec
> `infra/argocd/values.yaml`. La version du chart est suivie par Renovate (manuel). Ne plus faire de `helm upgrade`
> à la main — modifier `values.yaml` / `targetRevision` dans git.

CLI et connexion repo :

```bash
curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
argocd login argocd.mydomain.fr --username admin --grpc-web
argocd repo add git@github.com:Axtazer/harkesh-k8s.git --ssh-private-key-path ~/.ssh/id_ed25519 --grpc-web
```

Bootstrap de l'app-of-apps `root` (lit le dossier `argocd/`) :

```bash
argocd app create root --repo git@github.com:Axtazer/harkesh-k8s.git --path argocd --dest-server https://kubernetes.default.svc --dest-namespace argocd --sync-policy automated --auto-prune --self-heal --revision master --grpc-web
```

`root` déploie ensuite automatiquement :
- l'ApplicationSet `cluster-apps` (`argocd/applicationset.yaml`), qui crée une Application par dossier listé
  (`authentik`, `axtazer-me`, `bots`, `flo-pro`, `jellyfin`, `livekit`, `matrix`, `media-stack`, `monitoring`, `nextcloud`, `ntfy`, `pelican`, `shlink`) ;
- les Applications Helm dédiées : `argocd/argocd.yaml` (ArgoCD lui-même), `argocd/n8n.yaml`,
  `argocd/victoria-metrics-k8s-stack.yaml`, `argocd/dcgm-exporter.yaml`, `argocd/k8s-device-plugin.yaml`,
  `argocd/metrics-server.yaml`, `argocd/local-path-provisioner.yaml` ;
- les apps infra : `argocd/cilium.yaml`, `argocd/cilium-gateway.yaml`, `argocd/cloudflare-tunnel-controller.yaml`.

### 5. Monitoring (victoria-metrics-k8s-stack)

```bash
helm repo add victoria-metrics https://victoriametrics.github.io/helm-charts
helm install victoria-metrics-k8s-stack victoria-metrics/victoria-metrics-k8s-stack \
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
| `flo-pro-env` | `flo-pro-env` | `flo-pro` |
| `shlink` | `shlink-secrets` | `shlink` |
| `shlink-db` | `shlink-db-secret` | `shlink` |
| `axtazer-me` | `axtazer-secrets` | `axtazer-me` |
| `grafana-admin` | `grafana-admin` | `monitoring` |
| `cloudflare-analytics-token` | `cloudflare-analytics-token` | `monitoring` |
| `n8n` | `n8n-secrets` | `n8n` |
| `n8n-db` | `n8n-db-secrets` | `n8n` |
| `mullvad-credentials` | `mullvad-credentials` | `media` |
| `authentik` | `authentik-secret` | `authentik` |
| `matrix` | `matrix-secrets` | `matrix` |
| `draupnir` | `draupnir-secrets` | `matrix` |
| `maubot` | `maubot-secrets` | `matrix` |
| `livekit` | `livekit-secrets` | `livekit` |

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
Les versions déployées sont celles des manifests (tag + digest maintenus par Renovate) — pas de colonne
version ici : maintenue à la main, elle était systématiquement en retard sur les manifests.

| Service | Namespace | Accès externe | Accès interne K8s | Notes |
|---|---|---|---|---|
| axtazer.me | `axtazer-me` | `https://axtazer.me` | `http://axtazer-me.axtazer-me.svc.cluster.local:80` | |
| Shlink (raccourcisseur) | `shlink` | `https://go.axtazer.me` | `http://shlink.shlink.svc.cluster.local:80` | |
| Shlink Web Client | `shlink` | `https://shlink.axtazer.me` | `http://shlink-web.shlink.svc.cluster.local:80` | |
| PostgreSQL (shlink) | `shlink` | interne uniquement | `http://postgres.shlink.svc.cluster.local:5432` | |
| Flo-pro | `flo-pro` | `https://mydomain.fr` | `http://flo-pro.flo-pro.svc.cluster.local:80` | |
| Dev Flo-pro | `flo-pro` | `https://dev-pro.mydomain.fr` | `http://dev-flo-pro.flo-pro.svc.cluster.local:81` | |
| ArgoCD | `argocd` | `https://argocd.mydomain.fr` | — | |
| Grafana | `monitoring` | `https://grafana.mydomain.fr` | — | config via Helm values victoria-metrics-k8s-stack |
| Pelican Panel | `pelican` | `https://panel.axtazer.me` | `http://pelican-panel-svc.pelican.svc.cluster.local:80` | |
| Wings | `wings` | `https://node01.axtazer.me` | `http://wings-svc.wings.svc.cluster.local:8443` | |
| Nextcloud | `nextcloud` | `https://nas.mydomain.fr` | `http://nextcloud.nextcloud.svc.cluster.local:80` | |
| MariaDB (nextcloud) | `nextcloud` | interne uniquement | `http://mariadb.nextcloud.svc.cluster.local:3306` | |
| Redis (nextcloud) | `nextcloud` | interne uniquement | `http://redis.nextcloud.svc.cluster.local:6379` | |
| Jellyfin | `media` | `https://stream.axtazer.me` | `http://jellyfin.media.svc.cluster.local:8096` | Proxies connus : `10.0.0.0/8` |
| Prowlarr | `media` | `https://prowlarr.axtazer.me` | `http://prowlarr.media.svc.cluster.local:9696` | |
| Radarr | `media` | `https://radarr.axtazer.me` | `http://radarr.media.svc.cluster.local:7878` | |
| Sonarr | `media` | `https://sonarr.axtazer.me` | `http://sonarr.media.svc.cluster.local:8989` | |
| qBittorrent + Gluetun | `media` | `https://qbit.axtazer.me` | `http://qbittorrent.media.svc.cluster.local:8080` | VPN Mullvad WireGuard en sidecar |
| Seerr | `media` | `https://jellyseerr.axtazer.me` | `http://jellyseerr.media.svc.cluster.local:5055` | Fork Jellyseerr |
| n8n | `n8n` | `https://n8n.mydomain.fr` | `http://n8n.n8n.svc.cluster.local:5678` | |
| PostgreSQL (n8n) | `n8n` | interne uniquement | `http://postgres.n8n.svc.cluster.local:5432` | |
| Axtazia Bot | `bots` | `https://axtazia.axtazer.me/webhook/twitch` | `http://axtazia-bot.bots.svc.cluster.local:3000` | Webhook Twitch EventSub sur port 3000 |
| Authentik SSO | `authentik` | `https://auth.axtazer.me` | `http://authentik-server.authentik.svc.cluster.local:9000` | Provider SSO OIDC pour les autres apps |
| PostgreSQL (authentik) | `authentik` | interne uniquement | `http://postgresql.authentik.svc.cluster.local:5432` | |
| ntfy | `ntfy` | `https://ntfy.axtazer.me` | `http://ntfy.ntfy.svc.cluster.local:80` | Auth activée, `deny-all` par défaut |
| Matrix Synapse | `matrix` | `https://matrix.axtazer.me` | `http://synapse.matrix.svc.cluster.local:8008` | Homeserver privé, fédération fermée, inscriptions ouvertes à tout le monde sans vérification, aperçus de liens (URL previews) activés avec blacklist IP anti-SSRF |
| PostgreSQL (matrix) | `matrix` | interne uniquement | `http://postgres.matrix.svc.cluster.local:5432` | |
| Matrix well-known | `matrix` | `https://matrix.axtazer.me/.well-known/matrix/client` | — | Sert la découverte du service LiveKit (MSC4143) |
| Draupnir | `matrix` | interne uniquement (bot) | — | Modération (bans propagés, listes communautaires, admin homeserver) — remplaçant maintenu de Mjolnir, voir ci-dessous |
| Maubot | `matrix` | `https://maubot.axtazer.me/_matrix/maubot` | `http://maubot.matrix.svc.cluster.local:29316` | Bot à plugins — diffusion de flux RSS/Atom dans les salons (plugin `xyz.maubot.rss`), base SQLite sur le PVC, voir ci-dessous |
| LiveKit (SFU Element Call) | `livekit` | `wss://livekit.axtazer.me` | `http://livekit-signaling.livekit.svc.cluster.local:7880` | Signaling via Cloudflare Tunnel ; média (UDP/TCP) relayé via tunnel WireGuard → VPS `203.0.113.10` (voir section "Relais réseau LiveKit" ci-dessous) |
| lk-jwt-service | `livekit` | `https://livekit-jwt.axtazer.me` | `http://lk-jwt-service.livekit.svc.cluster.local:8080` | Émet les jetons LiveKit pour Element Call, homeserver autorisé : `matrix.axtazer.me` |
| cloudflare-tunnel-ingress-controller | `cloudflare-tunnel-ingress-controller` | — | — | Gère routes Cloudflare via Ingress K8s |
| **[archivé 2026-06-27]** AlterTrack | — | `https://altertrack.mydomain.fr` | — | Manifests dans `_archived/altertrack/` |
| **[archivé 2026-06-27]** PageBleue | — | `https://pagebleue.mydomain.fr` | — | Manifests dans `_archived/etudes/` |
| **[archivé 2026-07-05]** BetterStack collector | — | — | — | Manifests dans `_archived/betterstack-collector/` |

### Matrix — générer un token d'inscription

**État actuel** : les inscriptions sont ouvertes à tout le monde, sans token ni vérification
(`enable_registration_without_verification: true` + `registration_requires_token: false` dans
`matrix/matrix.yaml`). La procédure ci-dessous ne sert que si tu repasses en
`registration_requires_token: true` — recommandé pour un homeserver exposé publiquement
(comptes spam, remplissage du volume media — `max_upload_size` limité à `5G` en attendant).
Un compte admin (créé via `register_new_matrix_user -a`) est nécessaire pour générer un token.

```bash
# 1. Login pour récupérer un access_token (mot de passe saisi sans écho, jamais en clair dans l'historique)
read -s -p "Password admin: " ADMIN_PASSWORD; echo
ACCESS_TOKEN=$(curl -s https://matrix.axtazer.me/_matrix/client/v3/login \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"axtazer\"},\"password\":\"${ADMIN_PASSWORD}\"}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
unset ADMIN_PASSWORD

# 2. Créer un token (ici : 5 utilisations max, sans expiration — ajuster selon besoin)
curl -s -X POST https://matrix.axtazer.me/_synapse/admin/v1/registration_tokens/new \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d '{"uses_allowed": 5, "expiry_time": null}'
```

Le champ `"token"` de la réponse est à donner aux personnes invitées — elles le collent dans
Element au moment de l'inscription (`matrix.axtazer.me` comme homeserver).

### Draupnir — créer le compte bot

Draupnir a besoin d'un compte Matrix dédié pour agir en tant que modérateur.

```bash
# 1. Créer le compte (sur le pod synapse). Ajouter -a pour un compte admin homeserver
#    si tu veux utiliser les fonctions de modération au niveau serveur (suspension de
#    compte, blocage d'invitations, etc. — voir doc Draupnir "homeserver-administration").
kubectl exec -it -n matrix deploy/synapse -- register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008

# 2. Login pour récupérer l'access_token (mot de passe saisi sans écho)
read -s -p "Password draupnir: " BOT_PASSWORD; echo
curl -s https://matrix.axtazer.me/_matrix/client/v3/login \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"draupnir\"},\"password\":\"${BOT_PASSWORD}\"}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
unset BOT_PASSWORD
```

Mettre le token obtenu dans le champ `access-token` de l'item 1Password `draupnir`
(vault `k8s-home`). Au premier démarrage, Draupnir crée son salon de gestion et invite
le compte défini dans `initialManager` (`@axtazer:matrix.axtazer.me`) — c'est dans ce
salon que les commandes `!draupnir ...` se tapent.

### Maubot — créer le compte bot et diffuser des flux RSS

Maubot est un framework de bots Matrix à plugins ; le plugin officiel `xyz.maubot.rss`
poste les nouvelles entrées d'un flux RSS/Atom dans les salons abonnés. Le serveur est
déployé par GitOps (`matrix/maubot.yaml`), mais **le plugin et l'instance s'installent une
fois via l'interface web** — ils sont ensuite persistés sur le PVC
(`/srv/appdata/matrix/maubot`) et survivent aux redémarrages.

**1. Secrets** — créer l'item `maubot` dans le vault `k8s-home` avec deux champs générés
en hexadécimal (ils sont injectés par `sed` dans le template de config, donc pas de
caractère spécial) :

```bash
openssl rand -hex 32   # -> champ admin-password (login de l'interface web)
openssl rand -hex 32   # -> champ unshared-secret (signature des jetons d'API)
```

**2. Compte Matrix du bot** — même procédure que Draupnir, mais **sans** `-a` : le bot RSS
n'a besoin d'aucun droit d'administration sur le homeserver.

```bash
kubectl exec -it -n matrix deploy/synapse -- register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008
# utilisateur : rss   |   admin : no
```

**3. Interface web** — `https://maubot.axtazer.me/_matrix/maubot` (la racine `/` renvoie
404, c'est normal : l'UI est servie sous `ui_base_path`). Login **`axtazer`** + `admin-password`
— pas `root` : cet utilisateur ne peut jamais se connecter par mot de passe
(`check_password()` le refuse d'emblée), il n'existe que pour les jetons signés du CLI `mbc`.
⚠️ Cette interface donne un contrôle total sur le bot et sur les comptes Matrix qui y sont
connectés : la protéger par une policy **Cloudflare Access** comme les autres interfaces
d'admin.

**4. Client** — le formulaire de client de maubot 0.6 ne propose pas de login par mot de
passe (il n'a que `User ID`, `Homeserver`, `Access token`, `Device ID`…), il faut donc
récupérer un access_token comme pour Draupnir :

```bash
read -s -p "Password rss: " BOT_PASSWORD; echo
curl -s https://matrix.axtazer.me/_matrix/client/v3/login \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"rss\"},\"password\":\"${BOT_PASSWORD}\",\"initial_device_display_name\":\"maubot\"}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("access_token:", d["access_token"]); print("device_id: ", d["device_id"])'
unset BOT_PASSWORD
```

Puis dans l'UI, `Clients` → `+` : *User ID* `@rss:matrix.axtazer.me`, *Homeserver*
`matrix.axtazer.me` (entrée de la liste, elle pointe sur le Service interne
`synapse.matrix.svc.cluster.local:8008`), *Access token* et *Device ID* relevés ci-dessus,
puis **Sync**, **Autojoin** et **Enabled** activés — sans `Sync` le bot ne reçoit aucune
commande, sans `Autojoin` il n'accepte pas les invitations. Un display name et un avatar au
passage évitent un bot anonyme dans les salons.

**5. Plugin** — télécharger le `.mbp` de la dernière release du plugin RSS
(`xyz.maubot.rss-vX.Y.Z.mbp`, depuis <https://mau.dev/maubot/rss/-/releases> ou le miroir
<https://github.com/maubot/rss/releases>), puis dans l'UI : `Plugins` → `+` → uploader le
fichier. Le `.mbp` est stocké dans `/data/plugins` sur le PVC.

**6. Instance** — `Instances` → `+` : ID `rss`, *Primary user* = le client créé à
l'étape 4, *Type* = `xyz.maubot.rss`. Dans la config de l'instance (YAML à droite) :

```yaml
update_interval: 60          # minutes entre deux relevés des flux
command_prefix: "rss"        # commandes: !rss ...
notification_template: "New post in $feed_title: [$title]($link)"
allow_filter: false          # filtres regex réservés aux admins ci-dessous
admins:
- "@axtazer:matrix.axtazer.me"
```

**7. Utilisation** — inviter `@rss:matrix.axtazer.me` dans un salon, puis :

```text
!rss subscribe https://exemple.com/feed.xml   # abonner le salon (alias: !rss sub)
!rss subscriptions                            # lister les abonnements du salon
!rss unsubscribe <feed ID>                    # désabonner
!rss notice <feed ID> false                   # poster en message normal plutôt qu'en m.notice
!rss template <feed ID> <template>            # modèle de message ($feed_title, $title, $link, $summary, $date)
```

Par défaut, seuls les utilisateurs listés dans `admins` (config de l'instance) ou disposant
d'un niveau de pouvoir ≥ 50 dans le salon peuvent gérer les abonnements.

**Dépannage** — `kubectl logs -n matrix deploy/maubot` (logs sur stdout, pas de fichier).
Un flux qui ne remonte rien est en général un DROP réseau : les plages IP privées sont
bloquées en egress (anti-SSRF), donc un flux servi depuis le LAN ne fonctionnera pas —
vérifier avec
`kubectl exec -n kube-system ds/cilium -- hubble observe -n matrix --verdict DROPPED --follow`.

### LiveKit — relais réseau via VPS (Element Call)

Le Cloudflare Tunnel (HTTP/S uniquement) ne peut pas transporter le flux média WebRTC
(UDP) de LiveKit. `harkesh` étant derrière NAT sans IP publique routable, le flux média
est relayé via un tunnel **WireGuard** vers un VPS avec IP publique :

```
Participant  ──UDP/TCP──▶  VPS (203.0.113.10)  ──WireGuard──▶  pod livekit (10.10.0.2)
                            DNAT 7882/udp, 7881/tcp
```

- **Signaling** (WebSocket, port 7880) passe normalement par le Cloudflare Tunnel comme
  le reste — pas besoin du VPS pour ça.
- **Média** (UDP 7882 + TCP ICE 7881) : le VPS fait du DNAT + MASQUERADE (`iptables`,
  `/etc/ufw/before.rules`) vers `10.10.0.2` à travers le tunnel WireGuard.
- L'interface WireGuard tourne **dans le netns du pod `livekit`** (initContainer
  `wg-setup`, capability `NET_ADMIN`), pas sur l'hôte `harkesh` — évite toute
  interférence avec le routage de la machine (cf. incident du 2026-09-01 où WireGuard
  sur l'hôte cassait `cloudflared`).
- `config.yaml` de LiveKit force `node_ip: "203.0.113.10"` (IP du VPS) — c'est cette
  IP que LiveKit annonce aux clients comme candidat ICE, pas celle du pod/cluster.

**Config VPS** (`203.0.113.10`, Debian 13, Vexcloud) — `/etc/wireguard/wg0.conf` :
```
[Interface]
Address = 10.10.0.1/24
ListenPort = 51820
PrivateKey = <clé privée VPS>

[Peer]
# pod livekit
PublicKey = <clé publique du pod, voir ci-dessous>
AllowedIPs = 10.10.0.2/32
```

Ports ouverts côté VPS (`ufw`) : `51820/udp` (WireGuard), `7882/udp` + `7881/tcp` (média,
DNAT vers `10.10.0.2`). `net.ipv4.ip_forward=1` + `DEFAULT_FORWARD_POLICY="ACCEPT"`.

**Régénérer la clé WireGuard du pod** (si compromise/perdue) :
```bash
wg genkey | tee privatekey | wg pubkey  # noter la clé publique affichée
```
1. Mettre la clé **privée** dans le champ `wg-private-key` de l'item 1Password `livekit`
2. Mettre à jour le `PublicKey` du peer `# pod livekit` dans `/etc/wireguard/wg0.conf`
   sur le VPS, puis `sudo systemctl restart wg-quick@wg0`
3. Redémarrer le pod : `kubectl -n livekit rollout restart deploy/livekit`

## Renovate

Les images Docker sont suivies et mises à jour automatiquement via Renovate (config dans `renovate.json`).

| Image | Stratégie |
|---|---|
| `nextcloud` + `mariadb` + `redis` | Manuel — review obligatoire |
| `ghcr.io/pelican/*` | Automerge digest/patch/minor |
| `cloudflare-tunnel-ingress-controller` (Helm, manager `argocd`) | Automerge patch/minor |
| Charts Helm des Applications ArgoCD (`argo-cd`, `cilium`, `victoria-metrics-k8s-stack`, `dcgm-exporter`, `nvidia-device-plugin`, `metrics-server`, chart `n8n`) | Manuel — review obligatoire (manager `argocd` sur `argocd/*.yaml`) |
| CRDs Gateway API (`kubernetes-sigs/gateway-api`, `infra/cilium/gateway-api-crds.yaml`) | Manuel — doit rester dans la matrice de compatibilité de Cilium |
| `gcr.io/cadvisor/cadvisor` | Automerge digest/patch/minor |
| `ghcr.io/axtazer/axtazer-me` | Automerge digest |
| `ghcr.io/axtazer/axtazia` | Automerge digest (tag `latest`) + workflow `update-image` |
| `ghcr.io/axtazer/flo-pro` | Automerge digest (lookup limité — image GHCR privée, cf. workflow `update-image`) |
| `ghcr.io/shlinkio/shlink` + `shlink-web-client` | Automerge digest/patch/minor |
| `ghcr.io/goauthentik/server` | Automerge digest/patch/minor — major manuel (migrations BDD) |
| `binwiederhier/ntfy` | Automerge digest/patch/minor — major manuel |
| `matrixdotorg/synapse` | Manuel — review obligatoire (jamais d'automerge) |
| `gnuxie/draupnir` | Manuel — review obligatoire (jamais d'automerge, compte avec droits de modération/admin) |
| `dock.mau.dev/maubot/maubot` | Manuel — review obligatoire (jamais d'automerge, compte Matrix du bot + migrations de la base maubot/plugins) |
| `livekit/livekit-server` + `ghcr.io/element-hq/lk-jwt-service` + `lscr.io/linuxserver/wireguard` (sidecar) | Manuel — review obligatoire (jamais d'automerge, relais réseau critique) |
| `postgres` (shlink, n8n, authentik) | Automerge digest — major bloqué (migrations irréversibles) |
| `n8nio/n8n` | Automerge digest/patch/minor — major manuel |
| `busybox` + `nginx` (well-known Matrix) | Automerge digest/patch/minor |
| `yannh/kubeconform` + `mikefarah/yq` (CI) | Automerge digest/patch/minor |
| `jellyfin/jellyfin` | Automerge digest/patch — minor/major manuel |
| `lscr.io/linuxserver/*` + `ghcr.io/qdm12/gluetun` | Automerge digest/patch/minor |
| `ghcr.io/seerr-team/seerr` | Automerge digest/patch/minor — versioning semver forcé (registre à tags roulants) |
| Toutes les majors | Manuel — review obligatoire |
