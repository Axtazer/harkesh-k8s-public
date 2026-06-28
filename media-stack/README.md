# Media Stack — harkesh

Namespace `media`. Stack *arr complète avec VPN Mullvad via Gluetun.

---

## Services

| Service | URL externe | Port interne |
|---|---|---|
| Prowlarr | prowlarr.axtazer.me | 9696 |
| Radarr | radarr.axtazer.me | 7878 |
| Sonarr | sonarr.axtazer.me | 8989 |
| qBittorrent | qbit.axtazer.me | 8080 |
| Jellyseerr | jellyseerr.axtazer.me | 5055 |

## Adresses DNS internes (Kubernetes)

```
prowlarr.media.svc.cluster.local:9696
radarr.media.svc.cluster.local:7878
sonarr.media.svc.cluster.local:8989
qbittorrent.media.svc.cluster.local:8080
jellyseerr.media.svc.cluster.local:5055
```

---

## Stockage (hostPath sur /mnt/hdd)

```
/mnt/hdd/media/
├── config/
│   ├── prowlarr/
│   ├── radarr/
│   ├── sonarr/
│   ├── qbittorrent/
│   └── jellyseerr/
└── files/
    ├── films/       → monté /films  dans Radarr + qBittorrent
    ├── series/      → monté /series dans Sonarr + qBittorrent
    └── anime/       → monté /anime  dans Sonarr + qBittorrent
```

---

## Secrets 1Password

Vault `k8s-home`, item `mullvad-credentials` :

| Champ | Valeur |
|---|---|
| `wireguard-private-key` | Clé privée WireGuard Mullvad |
| `wireguard-address` | IP assignée à la clé (ex: `10.70.152.210/32`) |

Pour regénérer : mullvad.net → Account → WireGuard keys → Add key.
Mettre à jour 1Password puis `kubectl rollout restart deployment/qbittorrent -n media`.

---

## VPN (Gluetun + Mullvad WireGuard)

- Tous les téléchargements qBittorrent passent par le VPN
- Serveurs : Suède (`SERVER_COUNTRIES=Sweden`)
- MTU fixé à 1280 (Cilium overhead)
- Seul le pod qBittorrent est derrière le VPN — le reste de la stack (Radarr, Sonarr, etc.) accède internet directement

**Prérequis réseau :** port forward UDP 51820 → 192.168.1.201 sur le routeur (nécessaire pour que les réponses WireGuard reviennent au nœud).

---

## Configuration appliquée

### Prowlarr
- **Indexers** : C411 (privé FR), LimeTorrents (public), Nyaa.si (anime)
- **Apps** : Radarr + Sonarr synchronisés via API

### Radarr
- **Profil qualité** : 1080p (Bluray-1080p, WEB-1080p, WEBDL-1080p)
- **Custom Format** : French (score 10, non bloquant)
- **Root folder** : `/films`
- **Download client** : qBittorrent, catégorie `radarr`

### Sonarr
- **Profil qualité** : 1080p + Anime (séparé)
- **Root folders** : `/series` (séries), `/anime` (anime)
- **Download client** : qBittorrent, catégorie `tv-sonarr`

### Jellyseerr
- **Radarr** : profil 1080p, root `/films`, disponibilité Released
- **Sonarr** : profil 1080p, root `/series`
- **Sonarr Anime** : profil Anime, type Anime, root `/anime`
- Détection anime automatique via métadonnées TMDB/TVDB

### qBittorrent
- Credentials : `admin` / voir logs au premier démarrage
  ```bash
  kubectl logs -n media deployment/qbittorrent -c qbittorrent | grep -i password
  ```
- Catégories configurées : `radarr`, `tv-sonarr`

---

## Dépannage

**Gluetun ne se connecte pas (i/o timeout)**
1. Vérifier le port forward UDP 51820 sur le routeur
2. Vérifier la clé Mullvad sur mullvad.net
3. `kubectl exec -n media deploy/qbittorrent -c gluetun -- wg show`

**qBittorrent non accessible**
- Vérifier que Gluetun tourne : `kubectl get pods -n media`
- Les deux containers doivent être `Ready 2/2`

**Radarr/Sonarr ne trouvent rien**
- Vérifier la sync Prowlarr : Prowlarr → Indexers → tester chaque indexer
- Vérifier la connexion download client dans Radarr/Sonarr

**Ajouter FlareSolverr** (pour débloquer 1337x, TPB, etc.)
→ Pas encore déployé, à faire si besoin de plus d'indexers
