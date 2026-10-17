# CLAUDE.md — harkesh-k8s

## Rôle
Dépôt GitOps pour le cluster Kubernetes single-node **harkesh**.
Contient tous les manifests K8s, gérés via ArgoCD + Cloudflare Tunnel.

---

## Stack
| Composant | Outil |
|---|---|
| Orchestration | Kubernetes (single-node, kubeadm) |
| Réseau | Cilium (CNI, kube-proxy replacement, NetworkPolicies ; Gateway API conservé sans route, accès de secours) |
| GitOps | ArgoCD (app-of-apps `argocd/` + ApplicationSet `cluster-apps`) |
| Tunnel | Cloudflare Tunnel (seul chemin d'entrée : Internet → cloudflared → Service directement) |
| SSO | Authentik |
| Monitoring | victoria-metrics-k8s-stack (Helm, `argocd/`) + cAdvisor (conteneurs Docker Pelican) + blackbox-exporter (sites publics) ; alerting Grafana → ntfy |
| Logs | VictoriaLogs + collecteur vlagent (Helm, `argocd/victoria-logs.yaml`), datasource Grafana |
| Sécurité runtime | Tetragon (Helm, `argocd/tetragon.yaml`), Pod Security Admission warn/audit `restricted` |
| Secrets | 1Password Connect Operator (vault `k8s-home`) |
| Registry | GHCR (`ghcr.io/axtazer/`) |
| Updates externes | Renovate |
| Updates internes | Workflow `update-image` (repository_dispatch) |

---

## Structure
```
harkesh-k8s/
├── argocd/              # App-of-apps : root, ApplicationSet cluster-apps (list : dossier + namespace), Applications Helm (argo-cd auto-géré, cilium, VM stack, VictoriaLogs, Tetragon, nvidia, metrics-server, n8n, tunnel) + manifests upstream (local-path-provisioner)
├── authentik/           # Authentik SSO (server + worker + PostgreSQL)
├── axtazer-me/          # Site axtazer.me
├── bots/                # Axtazia bot (Discord/Twitch)
├── flo-pro/             # flo-pro (prod + dev)
├── french-breakfast/    # Croissanté — croissante.dev
├── infra/cilium/        # Values Cilium, Gateway shared-gateway, LB pool (sans annonce L2), App CRDs Gateway API
├── infra/cloudflare-tunnel-controller/ # cloudflare-tunnel-ingress-controller (gère le tunnel + le connecteur cloudflared)
├── infra/host/          # Scripts hôte hors ArgoCD : patch-apiserver.py (chiffrement etcd + audit), backup/ (restic → Hetzner Storage Box, timers systemd ; cf. README « Sauvegardes »)
├── jellyfin/            # Jellyfin (namespace media)
├── livekit/             # SFU Element Call — relais média via tunnel WireGuard vers VPS
├── matrix/              # Matrix Synapse (homeserver privé) + PostgreSQL + well-known
├── media-stack/         # Stack *arr (namespace media)
│   ├── secrets.yaml     #   OnePasswordItem mullvad-credentials
│   ├── prowlarr.yaml    #   Indexers — prowlarr.axtazer.me
│   ├── radarr.yaml      #   Films   — radarr.axtazer.me
│   ├── sonarr.yaml      #   Séries + anime — sonarr.axtazer.me
│   ├── qbittorrent.yaml #   Torrent + Gluetun VPN — qbit.axtazer.me
│   └── jellyseerr.yaml  #   Demandes médias — jellyseerr.axtazer.me
├── monitoring/          # cAdvisor (Docker Pelican), blackbox-exporter, dashboards (générés par dashboards/generate.py), datasources et alerting Grafana (le stack VM est dans argocd/)
├── n8n/                 # n8n automation
├── nextcloud/           # Nextcloud stack
├── ntfy/                # ntfy (notifications push)
├── pelican/             # Panel Pelican + Wings
├── root-panel/          # Panel admin root.axtazer.me (manifests seuls ; contenu dans le repo privé Axtazer/root-panel)
├── shlink/              # Raccourcisseur d'URL
├── _archived/           # Apps hors service (altertrack, pagebleue, betterstack-collector, ingress-nginx)
├── .github/workflows/
│   ├── update-image.yml # Mise à jour digests images internes
│   ├── validate.yml     # Validation kubeconform
│   └── mirror-public.yml # Miroir public : snapshot orphelin sanitisé (.github/scripts/mirror-sanitize.py)
└── renovate.json        # Config Renovate
```

---

## Workflow update-image

Déclenché par `repository_dispatch` (type `image-updated`) depuis les pipelines CI des apps internes.

**Apps supportées** (payload `app`) :
| app | fichier patché |
|---|---|
| `flo-pro` / `dev-flo-pro` | `flo-pro/web_flo-pro.yaml` / `flo-pro/dev_flo-pro.yaml` |
| `axtazer-me` | `axtazer-me/axtazer-me.yaml` |
| `axtazia` | `bots/axtazia.yaml` |
| `root-panel` | `root-panel/root-panel.yaml` |

Payload attendu côté CI de l'app (`gh api repos/Axtazer/harkesh-k8s/dispatches` ou action `peter-evans/repository-dispatch`) :
```json
{"event_type": "image-updated",
 "client_payload": {"app": "axtazia", "image": "ghcr.io/axtazer/axtazia", "digest": "sha256:<digest de l'image poussée>"}}
```

**Logique de branche** (`chore/update-images`) :
- Repart toujours de `master` (évite les conflits de rebase accumulés)
- Overlay de l'état existant de la branche en un seul commit squash
- Push avec `--force-with-lease` + retry `-X theirs` pour les runs concurrents
- PR vers master avec label `automerge` + `gh pr merge --auto --squash`

> ⚠️ Ne jamais revenir à `git rebase origin/master` sur cette branche — cause des conflits quand plusieurs digests du même fichier s'accumulent.

---

## Renovate

- Updates externes gérées automatiquement
- Charts Helm des Applications ArgoCD (`argocd/*.yaml`) suivis par le manager `argocd` — toujours manuel
- Les noms dans `matchPackageNames` doivent être **exactement** ceux des manifests (ex. `ghcr.io/pelican/*`,
  pas `pelican-dev`) — une règle qui ne matche pas échoue silencieusement (pas d'automerge, pas de groupe)
- Automerge activé pour : digests/patch/minor sur pelican, cloudflare-tunnel-ingress-controller, cAdvisor, blackbox-exporter, axtazia, axtazer-me, root-panel, flo-pro, french-breakfast, shlink, authentik, ntfy, n8n, media-stack, seerr, jellyfin (digest/patch), postgres (digest), busybox/nginx, outils CI, GitHub Actions — le détail fait foi dans `renovate.json`
- **Nextcloud** : toujours manuel (migrations BDD irréversibles)
- **MariaDB major** : désactivé (incompatible Nextcloud rolling release)
- Majors non couvertes : manuel + reviewer `Axtazer`
- **cloudflared** (connecteur de tunnel) : pas de manifest dédié — c'est un Deployment
  (`controlled-cloudflared-connector`) créé et géré dynamiquement à l'exécution par le
  controller `cloudflare-tunnel-ingress-controller` (image `ghcr.io/strrl/cloudflared`,
  tag non exposé via `values.yaml`). Sa version suit celle du controller ci-dessus —
  il n'y a rien à patcher côté GitOps pour lui spécifiquement.

---

## Conventions
- Commits conventionnels : `feat:`, `fix:`, `chore:`, `docs:`
- Master protégé — toujours passer par une PR + status check `validate`
- `imagePullSecrets: ghcr-secret` à créer manuellement après réinstall
- Secrets via `OnePasswordItem` (vault `k8s-home`)
- `routes.yaml` = `Ingress` cloudflare-tunnel uniquement. Pas d'`HTTPRoute` : l'accès LAN direct est désactivé (contournait Cloudflare Access), le Gateway Cilium reste en place pour un accès de secours (procédure dans le README)
- NetworkPolicies : deny-all (ingress + egress) + allow ciblés dans tous les namespaces applicatifs, flux documentés en tête de fichier (modèles : `n8n/`, `media-stack/`, `matrix/`). Hôte / API server = `CiliumNetworkPolicy` `toEntities` (un `ipBlock` ne matche pas l'IP du nœud). Toute nouvelle app doit ajouter son `networkpolicy.yaml` ; vérifier avec `kubectl exec -n kube-system ds/cilium -- hubble observe -n <ns> --verdict DROPPED --follow`
- Pod Security Admission : chaque `Namespace` porte `pod-security.kubernetes.io/warn` + `audit: restricted` (signalement seulement, pas d'`enforce`) ; une nouvelle app ajoute ces labels à son Namespace
- `automountServiceAccountToken: false` sur tout pod (aucune app n'utilise l'API K8s)
- securityContext : `seccompProfile: RuntimeDefault` au niveau pod et `allowPrivilegeEscalation: false` sur chaque conteneur ; image non-root (USER numérique vérifié) → en plus `runAsNonRoot` + `capabilities.drop: ["ALL"]`. Images qui démarrent en root puis baissent leurs droits (postgres, mariadb, linuxserver, nextcloud…) : pas de `drop: ALL` (elles ont besoin de CHOWN/SETUID). Exceptions : Wings et cAdvisor (privileged)
- Images linuxserver (media-stack) : `PUID=1000` / `PGID=984` (groupe `media`, propriétaire de `/mnt/hdd/media`), jamais root
- Ajout d'une app dans l'ApplicationSet = une entrée `{app, namespace}` dans `argocd/applicationset.yaml`
- Grafana : rien en clic dans l'UI (base en `emptyDir`, perdu au redémarrage). Dashboards = `monitoring/dashboards/generate.py` (grafana.com épinglé par révision ou JSON maison dans `monitoring/dashboards/`) → ConfigMaps générées `monitoring/grafana-dashboards-<dossier>.yaml`, jamais éditées à la main (check CI `--check`). Pas de dashboard qui dépend de recording rules (vmalert désactivé)
- Alerting : uniquement Grafana (pas d'alertmanager/vmalert), provisionné dans `monitoring/grafana-alerting.yaml` (ConfigMaps `grafana_alert`), notifications ntfy topic `grafana` par l'URL interne ; label `severity` = `critical` (priorité 5) ou `warning` (priorité 3). Dans ces fichiers un `$` littéral s'écrit `$$` (interpolation des variables d'env par Grafana) : modèles en `.Labels` / `.Values`
- Pas de colonne « version » dans le README : la version de référence est le manifest (Renovate la maintient)
- Pas d'`imagePullPolicy: Always` sur une image pinnée par digest (immutable, ajoute juste une dépendance au registre au démarrage)
- Nouveau PV/PVC hostPath : `storageClassName: ""` des deux côtés (cf. `authentik/`) pour ne jamais dépendre d'une StorageClass par défaut ; ne pas modifier ce champ sur un PVC déjà lié (immutable)
- Métriques des scripts de l'hôte : fichiers `*.prom` dans `/var/lib/node_exporter/textfile` (collecteur textfile de node-exporter, via `/host/root`), écrits atomiquement (tmp + mv) et lisibles par nobody (644) ; cf. `harkesh-backup.sh`
- Sauvegardes : une nouvelle app avec des données ajoute son chemin à `infra/host/backup/paths.txt` (et son dump dans `harkesh-backup.sh` si elle a une base) ; les fichiers bruts de base vont dans `excludes.txt`
- Ajout d'une app : toujours mettre à jour `renovate.json` (pattern `managerFilePatterns` + règle automerge/major) et `README.md` (structure, table Services, table Renovate) dans la même PR
- Suppression d'une app : ne jamais supprimer les manifests — les déplacer dans `_archived/<app>/`, retirer son entrée de `argocd/applicationset.yaml`, et marquer la ligne correspondante du README comme `**[archivé YYYY-MM-DD]**` (voir AlterTrack/PageBleue)
