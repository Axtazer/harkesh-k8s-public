# harkesh-k8s

Manifests Kubernetes pour le homelab. Les secrets sont gérés via **1Password Connect Operator** et les déploiements via **ArgoCD** (GitOps). Les images sont surveillées et mises à jour automatiquement par **Renovate**.

## Documentation

Toute la documentation d'exploitation est dans [`_docs/`](_docs/README.md), rangée par sujet :
[architecture réseau](_docs/architecture.md), [services](_docs/services.md), [sécurité](_docs/securite.md),
[secrets](_docs/secrets.md), [backup](_docs/backup.md), [hôte](_docs/hote.md), [monitoring](_docs/monitoring.md),
[Renovate](_docs/renovate.md), [Cloudflare Tunnel](_docs/cloudflare-tunnel.md), [réinstallation](_docs/reinstallation.md)
et les pages d'apps ([Matrix](_docs/apps/matrix.md), [LiveKit](_docs/apps/livekit.md), [media stack](_docs/apps/media-stack.md)).

## Structure

```
/
├── _archived/                     # Apps hors service (manifests conservés pour référence)
│   ├── altertrack/                #   AlterTrack (archivé 2026-06-27)
│   ├── betterstack-collector/     #   BetterStack collector (archivé 2026-07-05)
│   ├── etudes/                    #   PageBleue (archivé 2026-06-27)
│   ├── ingress-nginx/             #   ingress-nginx (archivé 2026-09-07, remplacé par Cilium Gateway API)
│   └── media-share/               #   media-share (archivé 2026-10-11)
├── _docs/                         # Documentation d'exploitation par sujet (sommaire : _docs/README.md)
│   ├── architecture.md · services.md · securite.md · secrets.md
│   ├── backup.md · hote.md · monitoring.md · endpoints.md · renovate.md · cloudflare-tunnel.md · cloudflare.md · reinstallation.md
│   ├── apps/                      #   Procédures propres à une app (matrix, livekit, media-stack)
│   └── archives/                  #   Procédures terminées, conservées pour référence
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
│   ├── prometheus-operator-crds.yaml # App Helm CRDs prometheus-operator (ServiceMonitor… reprises de l'ancien kube-prometheus-stack)
│   ├── tetragon.yaml              # App Helm Tetragon (observabilité sécurité eBPF, export restreint → VictoriaLogs)
│   ├── victoria-logs.yaml         # App Helm VictoriaLogs + collecteur vlagent (logs centralisés, 14 j)
│   ├── victoria-metrics-k8s-stack.yaml # App Helm victoria-metrics-k8s-stack (Grafana/VictoriaMetrics)
│   ├── n8n.yaml                   # App Helm n8n (8gears/n8n-helm-chart)
│   ├── onepassword-connect.yaml   # App Helm 1Password Connect + operator (Secrets d'accès hors Git)
│   ├── namespace.yaml             # Namespace argocd (label shared-gateway-access)
│   └── root-app.yaml              # Bootstrap : root Application (lit argocd/)
├── alchimie-creatures/
│   ├── alchimie-creatures.yaml    # Jeu Alchimie & Créatures (alchimie.mydomain2.fr)
│   ├── networkpolicy.yaml         # NetworkPolicies (deny-all + allow ciblés)
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── axtazer-me/
│   ├── axtazer-me.yaml            # Site mydomain2.fr
│   ├── networkpolicy.yaml         # NetworkPolicies (deny-all + allow ciblés)
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── bots/
│   ├── axtazia.yaml               # Bot Discord/Twitch Axtazia + Service webhook Twitch
│   ├── networkpolicy.yaml         # NetworkPolicies (deny-all + allow ciblés)
│   └── routes.yaml                # Ingress cloudflare-tunnel /webhook/twitch
├── flo-pro/
│   ├── dev_flo-pro.yaml           # Dev Flo-Pro web
│   ├── namespace.yaml             # Namespace flo-pro (label shared-gateway-access)
│   ├── networkpolicy.yaml         # NetworkPolicies (deny-all + allow ciblés)
│   ├── routes.yaml                # Ingress cloudflare-tunnel
│   └── web_flo-pro.yaml           # Flo-Pro web
├── french-breakfast/
│   ├── french-breakfast.yaml      # Croissanté (« croissanter » un PC déverrouillé) — sans état, aucun secret
│   ├── networkpolicy.yaml         # NetworkPolicies (deny-all + allow ciblés)
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── infra/
│   ├── argocd/
│   │   └── values.yaml            # Values Helm argo-cd (server.insecure) — bootstrap + argocd/argocd.yaml
│   ├── cilium/
│   │   ├── gateway-api-crds.yaml  # App ArgoCD Gateway API CRDs (sync-wave -1)
│   │   ├── gateway.yaml           # shared-gateway (kube-system, Cilium Gateway API) — aucune route active, accès de secours
│   │   ├── lb-pool.yaml           # CiliumLoadBalancerIPPool 192.168.1.203/32 (pas d'annonce L2)
│   │   └── values.yaml            # Values Helm Cilium (gatewayAPI, l2announcements…)
│   ├── cloudflare-tunnel-controller/
│   │   ├── secret.yaml            # OnePasswordItem cloudflare-tunnel-controller
│   │   └── values.yaml            # Values Helm tunnel controller
│   └── host/
│       ├── backup/                # Sauvegarde restic → Hetzner Storage Box (script, chemins/exclusions, timers systemd)
│       └── patch-apiserver.py     # Chiffrement etcd + audit : patch du manifest kube-apiserver et de kubeadm-config (hors ArgoCD)
├── jellyfin/
│   ├── jellyfin.yaml              # Jellyfin
│   ├── networkpolicy.yaml         # NetworkPolicies Jellyfin (deny-all du namespace media dans media-stack/)
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── livekit/                        # SFU Element Call (appels audio/vidéo Matrix)
│   ├── livekit.yaml                #   LiveKit server + sidecar WireGuard (relais VPS)
│   ├── jwt-service.yaml            #   lk-jwt-service (auth Element Call <-> LiveKit)
│   ├── networkpolicy.yaml          #   NetworkPolicies (deny-all + cloudflared, WireGuard vers le VPS)
│   └── routes.yaml                 #   Ingress cloudflare-tunnel livekit.mydomain2.fr + livekit-jwt.mydomain2.fr
├── matrix/
│   ├── matrix.yaml                 # Synapse + PostgreSQL + secrets 1Password + PV/PVC
│   ├── wellknown.yaml               #   /.well-known/matrix/client (découverte LiveKit)
│   ├── draupnir.yaml                #   Bot de modération (remplaçant maintenu de Mjolnir)
│   ├── maubot.yaml                  #   Maubot + plugin RSS (diffusion de flux dans les salons)
│   ├── networkpolicy.yaml           #   NetworkPolicies (deny-all + flux synapse/postgres/draupnir/maubot/well-known)
│   └── routes.yaml                 # Ingress cloudflare-tunnel (matrix.mydomain2.fr + maubot.mydomain2.fr)
├── media-stack/                   # Stack *arr (namespace media)
│   ├── secrets.yaml               #   OnePasswordItem mullvad-credentials
│   ├── prowlarr.yaml              #   Indexers — prowlarr.mydomain2.fr
│   ├── radarr.yaml                #   Films — radarr.mydomain2.fr
│   ├── sonarr.yaml                #   Séries + anime — sonarr.mydomain2.fr
│   ├── qbittorrent.yaml           #   Torrent + Gluetun VPN — qbit.mydomain2.fr
│   ├── jellyseerr.yaml            #   Seerr (fork Jellyseerr) — jellyseerr.mydomain2.fr
│   ├── networkpolicy.yaml         #   NetworkPolicies namespace media (deny-all + flux *arr/qBittorrent/Seerr)
│   └── routes.yaml                #   Ingress cloudflare-tunnel (toute la stack)
├── monitoring/
│   ├── blackbox-exporter.yaml      # blackbox-exporter + VMProbe : sondes HTTPS des sites publics (tunnel, certificats)
│   ├── cadvisor.yaml               # DaemonSet cAdvisor + Service + ServiceMonitor
│   ├── grafana-alerting.yaml       # Alerting Grafana provisionné : modèle + contact point ntfy, politique, règles
│   ├── grafana-onepassword.yaml    # OnePasswordItem grafana-admin + cloudflare-analytics-token + grafana-ntfy-token
│   ├── dashboards/                 # Sources des dashboards (non lu par ArgoCD) : generate.py + JSON maison
│   ├── grafana-dashboards-*.yaml   # ConfigMaps dashboards GÉNÉRÉES par dashboards/generate.py (un fichier par dossier Grafana)
│   ├── grafana-datasource-cloudflare.yaml # ConfigMap datasource Grafana yesoreyeram-infinity (Cloudflare GraphQL API)
│   ├── grafana-datasource-victorialogs.yaml # ConfigMap datasource Grafana VictoriaLogs
│   ├── namespace.yaml             # Namespace monitoring (label shared-gateway-access)
│   ├── networkpolicy.yaml         # NetworkPolicies + CiliumNetworkPolicies (scrapes vmagent, API server, hôte)
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
│   ├── networkpolicy.yaml         # NetworkPolicies (deny-all + allow ciblés)
│   └── routes.yaml                # Ingress cloudflare-tunnel → auth.mydomain2.fr
├── nextcloud/
│   ├── nextcloud.yaml             # Nextcloud + MariaDB + Redis
│   ├── networkpolicy.yaml         # NetworkPolicies (deny-all + allow ciblés)
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── ntfy/
│   ├── networkpolicy.yaml         # NetworkPolicies (deny-all + allow ciblés)
│   ├── ntfy.yaml                   # ntfy (serveur notifications push) + PV/PVC persistant
│   └── routes.yaml                # Ingress cloudflare-tunnel
├── pelican/
│   ├── networkpolicy.yaml         # NetworkPolicies Panel (+ CNP Panel → Wings) et deny-all du namespace wings
│   ├── panel.yaml                 # Pelican Panel + Services
│   ├── routes.yaml                # Ingress cloudflare-tunnel panel + wings
│   └── wings.yaml                 # Wings (daemon Pelican)
├── root-panel/
│   ├── networkpolicy.yaml         # NetworkPolicies (deny-all + cloudflared, aucun egress)
│   ├── root-panel.yaml            # Panel admin (image privée ghcr.io/axtazer/root-panel, contenu dans le repo Axtazer/root-panel)
│   └── routes.yaml                # Ingress cloudflare-tunnel → root.mydomain2.fr
├── shlink/
│   ├── networkpolicy.yaml         # NetworkPolicies (deny-all + allow ciblés)
│   ├── shlink.yaml                # Shlink URL shortener + Web client + PostgreSQL
│   └── routes.yaml                # Ingress cloudflare-tunnel go + shlink-web
└── renovate.json                  # Config Renovate (image tracking)
```
