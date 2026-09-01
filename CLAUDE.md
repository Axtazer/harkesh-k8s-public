# CLAUDE.md — harkesh-k8s

## Rôle
Dépôt GitOps pour le cluster Kubernetes single-node **harkesh**.
Contient tous les manifests K8s, gérés via ArgoCD + Cloudflare Tunnel.

---

## Stack
| Composant | Outil |
|---|---|
| Orchestration | Kubernetes (single-node) |
| GitOps | ArgoCD |
| Tunnel | Cloudflare Tunnel |
| Secrets | 1Password Connect Operator (vault `k8s-home`) |
| Registry | GHCR (`ghcr.io/axtazer/`) |
| Updates externes | Renovate |
| Updates internes | Workflow `update-image` (repository_dispatch) |

---

## Structure
```
harkesh-k8s/
├── argocd/              # ArgoCD config
├── axtazer-me/          # Site axtazer.me
├── bots/                # Axtazia bot + Warframe bot
├── flo-pro/             # flo-pro (prod + dev)
├── infra/cloudflared/   # Cloudflare Tunnel
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
├── monitoring/          # cAdvisor + kube-prometheus-stack
├── n8n/                 # n8n automation
├── nextcloud/           # Nextcloud stack
├── ntfy/                # ntfy (notifications push)
├── ollama/              # Ollama LLM
├── pelican/             # Panel Pelican + Wings
├── shlink/              # Raccourcisseur d'URL
├── _archived/           # Apps hors service (altertrack, pagebleue)
├── .github/workflows/
│   ├── update-image.yml # Mise à jour digests images internes
│   ├── validate.yml     # Validation kubeconform
│   └── mirror-public.yml
└── renovate.json        # Config Renovate
```

---

## Workflow update-image

Déclenché par `repository_dispatch` (type `image-updated`) depuis les pipelines CI des apps internes.

**Apps supportées** (payload `app`) :
| app | fichier patché |
|---|---|
| `flo-pro` / `dev-flo-pro` | `flo-pro/web_flo-pro.yaml` / `flo-pro/dev_flo-pro.yaml` |

**Logique de branche** (`chore/update-images`) :
- Repart toujours de `master` (évite les conflits de rebase accumulés)
- Overlay de l'état existant de la branche en un seul commit squash
- Push avec `--force-with-lease` + retry `-X theirs` pour les runs concurrents
- PR vers master avec label `automerge` + `gh pr merge --auto --squash`

> ⚠️ Ne jamais revenir à `git rebase origin/master` sur cette branche — cause des conflits quand plusieurs digests du même fichier s'accumulent.

---

## Renovate

- Updates externes gérées automatiquement
- Automerge activé pour : digests/patch/minor sur pelican, cloudflared, cAdvisor, axtazia, flo-pro, delivreou, GitHub Actions
- **Nextcloud** : toujours manuel (migrations BDD irréversibles)
- **MariaDB major** : désactivé (incompatible Nextcloud rolling release)
- Majors non couvertes : manuel + reviewer `Axtazer`

---

## Conventions
- Commits conventionnels : `feat:`, `fix:`, `chore:`, `docs:`
- Master protégé — toujours passer par une PR + status check `validate`
- `imagePullSecrets: ghcr-secret` à créer manuellement après réinstall
- Secrets via `OnePasswordItem` (vault `k8s-home`)
- Ajout d'une app : toujours mettre à jour `renovate.json` (pattern `managerFilePatterns` + règle automerge/major) et `README.md` (structure, table Services, table Renovate) dans la même PR
- Suppression d'une app : ne jamais supprimer les manifests — les déplacer dans `_archived/<app>/`, retirer l'entrée de `argocd/applicationset.yaml`, et marquer la ligne correspondante du README comme `**[archivé YYYY-MM-DD]**` (voir AlterTrack/PageBleue)
