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
├── altertrack/          # AlterTrack webapp
├── argocd/              # ArgoCD config
├── bots/                # Axtazia bot
├── cloudflared/         # Cloudflare Tunnel
├── etudes/              # Apps étudiantes (delivreou, PageBleue)
├── flo-pro/             # flo-pro (prod + dev)
├── monitoring/          # cAdvisor
├── pelican/             # Panel Pelican
├── storageServices/     # Nextcloud stack
├── wings/               # Wings (Pelican)
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
| `altertrack` / `dev-altertrack` | `altertrack/altertrack.yaml` |
| `flo-pro` / `dev-flo-pro` | `flo-pro/web_flo-pro.yaml` / `flo-pro/dev_flo-pro.yaml` |
| `delivreou` | `etudes/delivreou/delivreou-full.yaml` |
| `pagebleue` | `etudes/PageBleue/pagebleue.yaml` |

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
