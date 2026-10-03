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

## Stockage (hostPath)

**Config des apps** : `/srv/appdata/<app>` sur l'hôte (prowlarr, radarr, sonarr, qbittorrent,
jellyseerr), monté sur `/config` dans le conteneur (`/app/config` pour Seerr).

**Médias** : `/mnt/hdd/media` monté **tel quel sur `/data`** dans Radarr, Sonarr et qBittorrent —
même arborescence partout, ce qui permet les hardlinks / déplacements atomiques entre le dossier
de téléchargement et les root folders. Jellyfin monte `/mnt/hdd/media/files` en lecture seule sur `/media`.

```
/mnt/hdd/media/                → /data (Radarr, Sonarr, qBittorrent)
├── downloads/                 → /data/downloads (qBittorrent)
└── files/                     → /media (Jellyfin, lecture seule)
    ├── films/                 → root folder Radarr   : /data/files/films
    ├── series/                → root folder Sonarr   : /data/files/series
    └── anime/                 → root folder Sonarr   : /data/files/anime (profil Anime)
```

**Permissions** : Prowlarr, Radarr, Sonarr et qBittorrent tournent en `PUID=1000` (`flo`) / `PGID=984`
(groupe `media`, propriétaire de `/mnt/hdd/media`, dossiers `2775` avec setgid) et `UMASK=002`, jamais en root.
L'init linuxserver fait `lsiown -R 1000:984 /config` à chaque démarrage, donc rien à faire sur
`/srv/appdata/<app>` (un `chown -R 1000:984` préalable évite juste un démarrage plus long).
Les fichiers média créés avant ce changement appartiennent à root mais restent gérables : les
déplacements/suppressions ne demandent que le droit d'écriture sur le dossier (groupe 984).

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
- Serveurs : France, Suisse (`SERVER_COUNTRIES=France,Switzerland`)
- MTU fixé à 1280 (Cilium overhead)
- Seul le pod qBittorrent est derrière le VPN — le reste de la stack (Radarr, Sonarr, etc.) accède internet directement
- Gluetun est déclaré comme **native sidecar** (`initContainers` + `restartPolicy: Always`) avec un `startupProbe` sur `/gluetun-entrypoint healthcheck` (port santé interne `127.0.0.1:9999`) : le container `qbittorrent` ne démarre que lorsque le tunnel WireGuard est établi et validé, ce qui garantit que qBittorrent ne peut jamais émettre de trafic avant que le VPN soit ON

**Aucun port forward n'est nécessaire sur le routeur.** Gluetun est un *client* WireGuard : c'est le pod
qui ouvre le flux UDP vers le serveur Mullvad, et les réponses reviennent par l'entrée de conntrack créée
par le NAT — comme pour n'importe quelle connexion sortante.

> Une version précédente de ce fichier demandait une redirection `UDP 51820` vers le nœud, « nécessaire
> pour que les réponses WireGuard reviennent ». C'était faux, et la règle n'a jamais servi à rien. Elle
> est même devenue nuisible après un changement d'IP du nœud : l'ancienne adresse ayant été réattribuée
> par le DHCP, la redirection envoyait du trafic à une machine tierce du LAN.
>
> Un port entrant pour les peers BitTorrent ne se règle pas non plus ici : les pairs se connectent à l'IP
> de sortie Mullvad, jamais à l'IP publique de la maison. Il faudrait le port forwarding côté Mullvad —
> fonctionnalité que Mullvad a supprimée. Le dépôt ne configure donc ni `VPN_PORT_FORWARDING` ni
> `FIREWALL_VPN_INPUT_PORTS` ; seul `FIREWALL_INPUT_PORTS=8080` est ouvert, pour la WebUI jointe via
> le tunnel Cloudflare.

---

## Configuration appliquée

### Prowlarr
- **Indexers** : C411 (privé FR), LimeTorrents (public), Nyaa.si (anime)
- **Apps** : Radarr + Sonarr synchronisés via API

### Radarr
- **Profil qualité** : 1080p (Bluray-1080p, WEB-1080p, WEBDL-1080p)
- **Custom Format** : French (score 10, non bloquant)
- **Root folder** : `/data/files/films`
- **Download client** : qBittorrent, catégorie `radarr`

### Sonarr
- **Profil qualité** : 1080p + Anime (séparé)
- **Root folders** : `/data/files/series` (séries), `/data/files/anime` (anime)
- **Download client** : qBittorrent, catégorie `tv-sonarr`

### Seerr (ex-Jellyseerr, image `ghcr.io/seerr-team/seerr`)
- **Radarr** : profil 1080p, root `/data/files/films`, disponibilité Released
- **Sonarr** : profil 1080p, root `/data/files/series`
- **Sonarr Anime** : profil Anime, type Anime, root `/data/files/anime`
- Détection anime automatique via métadonnées TMDB/TVDB

### qBittorrent
- Credentials : `admin` / voir logs au premier démarrage
  ```bash
  kubectl logs -n media deployment/qbittorrent -c qbittorrent | grep -i password
  ```
- Catégories configurées : `radarr`, `tv-sonarr`

---

## Réseau (NetworkPolicies)

Namespace en deny-all (ingress + egress), voir `networkpolicy.yaml` (stack *arr) et `jellyfin/networkpolicy.yaml`.
Flux autorisés :

| Source | Destination |
|---|---|
| cloudflared (tunnel) | toutes les web UIs |
| Seerr | Radarr, Sonarr, Jellyfin |
| Prowlarr | Radarr, Sonarr (sync) |
| Radarr, Sonarr | Prowlarr (recherches), qBittorrent (download client), Jellyfin (notification Connect) |
| Prowlarr, Radarr, Sonarr, Seerr, Jellyfin | Internet 80/443 uniquement |
| qBittorrent (gluetun) | Internet tout port (tunnel WireGuard), jamais les plages privées |

Un indexer Prowlarr sur un port non standard (ni 80 ni 443) doit être ajouté à `arr-allow-egress-internet`.
Pour voir ce qui est bloqué (la CLI hubble est dans l'agent Cilium, pas sur l'hôte) :
`kubectl exec -n kube-system ds/cilium -- hubble observe -n media --verdict DROPPED --follow`.

---

## Dépannage

**Gluetun ne se connecte pas (i/o timeout)**
1. Vérifier que le nœud a bien un accès sortant UDP (aucun port forward n'est requis, voir section VPN)
2. Vérifier la clé Mullvad sur mullvad.net
3. `kubectl exec -n media deploy/qbittorrent -c gluetun -- wg show`

**qBittorrent non accessible**
- Vérifier que Gluetun tourne : `kubectl get pods -n media`
- Les deux containers doivent être `Ready 2/2`
- Le container `qbittorrent` reste en attente (`Init`) tant que le `startupProbe` de Gluetun n'est pas passant — c'est voulu (voir section VPN ci-dessus)

**qBittorrent affiche "IP externe : N/A"**
- Juste après un redémarrage du pod, c'est normal : qBittorrent ne peut démarrer qu'une fois le tunnel Gluetun confirmé UP (`startupProbe`), et il lui faut ensuite quelques connexions pairs/DHT actives pour déterminer son IP externe — ça se résorbe en général en 1-2 minutes
- Si ça persiste : vérifier que Gluetun a bien récupéré une IP publique (`kubectl logs -n media deploy/qbittorrent -c gluetun | grep "Public IP"`). Sans port entrant côté Mullvad, qBittorrent reste en mode connexions sortantes uniquement — c'est attendu, et sans effet sur les téléchargements

**Radarr/Sonarr ne trouvent rien**
- Vérifier la sync Prowlarr : Prowlarr → Indexers → tester chaque indexer
- Vérifier la connexion download client dans Radarr/Sonarr

**Ajouter FlareSolverr** (pour débloquer 1337x, TPB, etc.)
→ Pas encore déployé, à faire si besoin de plus d'indexers
