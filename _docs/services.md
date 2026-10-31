[← Sommaire](README.md)


# Services

Tous les accès externes passent par le **Cloudflare Tunnel** — aucun port exposé sur le routeur.
`Accès interne K8s` = adresse joignable depuis un autre pod du cluster (`<service>.<namespace>.svc.cluster.local:<port>`).
Les versions déployées sont celles des manifests (tag + digest maintenus par Renovate) — pas de colonne
version ici : maintenue à la main, elle était systématiquement en retard sur les manifests.

| Service | Namespace | Accès externe | Accès interne K8s | Notes |
|---|---|---|---|---|
| Alchimie & Créatures | `alchimie-creatures` | `https://alchimie.mydomain2.fr` | `http://alchimie-creatures.alchimie-creatures.svc.cluster.local:80` | Jeu statique, aucune donnée serveur |
| mydomain2.fr | `axtazer-me` | `https://mydomain2.fr` | `http://axtazer-me.axtazer-me.svc.cluster.local:80` | |
| Shlink (raccourcisseur) | `shlink` | `https://go.mydomain2.fr` | `http://shlink.shlink.svc.cluster.local:80` | |
| Shlink Web Client | `shlink` | `https://shlink.mydomain2.fr` | `http://shlink-web.shlink.svc.cluster.local:80` | |
| PostgreSQL (shlink) | `shlink` | interne uniquement | `http://postgres.shlink.svc.cluster.local:5432` | |
| Flo-pro | `flo-pro` | `https://mydomain.fr` | `http://flo-pro.flo-pro.svc.cluster.local:80` | |
| Dev Flo-pro | `flo-pro` | `https://dev-pro.mydomain.fr` | `http://dev-flo-pro.flo-pro.svc.cluster.local:81` | |
| Croissanté (french-breakfast) | `french-breakfast` | `https://croissante.dev` | `http://french-breakfast.french-breakfast.svc.cluster.local:80` | Sans état, aucun secret, image GHCR publique (pas de `ghcr-secret`) |
| ArgoCD | `argocd` | `https://argocd.mydomain.fr` | — | |
| Grafana | `monitoring` | `https://grafana.mydomain.fr` | — | config via Helm values victoria-metrics-k8s-stack ; dashboards : [Monitoring](monitoring.md) |
| Pelican Panel | `pelican` | `https://panel.mydomain2.fr` | `http://pelican-panel-svc.pelican.svc.cluster.local:80` | |
| Wings | `wings` | `https://node01.mydomain2.fr` | `http://wings-svc.wings.svc.cluster.local:8443` | |
| Nextcloud | `nextcloud` | `https://nas.mydomain.fr` | `http://nextcloud.nextcloud.svc.cluster.local:80` | |
| MariaDB (nextcloud) | `nextcloud` | interne uniquement | `http://mariadb.nextcloud.svc.cluster.local:3306` | |
| Redis (nextcloud) | `nextcloud` | interne uniquement | `http://redis.nextcloud.svc.cluster.local:6379` | |
| Jellyfin | `media` | `https://stream.mydomain2.fr` | `http://jellyfin.media.svc.cluster.local:8096` | Proxies connus : `10.0.0.0/8` |
| Prowlarr | `media` | `https://prowlarr.mydomain2.fr` | `http://prowlarr.media.svc.cluster.local:9696` | |
| Radarr | `media` | `https://radarr.mydomain2.fr` | `http://radarr.media.svc.cluster.local:7878` | |
| Sonarr | `media` | `https://sonarr.mydomain2.fr` | `http://sonarr.media.svc.cluster.local:8989` | |
| qBittorrent + Gluetun | `media` | `https://qbit.mydomain2.fr` | `http://qbittorrent.media.svc.cluster.local:8080` | VPN Mullvad WireGuard en sidecar |
| Seerr | `media` | `https://jellyseerr.mydomain2.fr` | `http://jellyseerr.media.svc.cluster.local:5055` | Fork Jellyseerr |
| n8n | `n8n` | `https://n8n.mydomain.fr` | `http://n8n.n8n.svc.cluster.local:5678` | |
| PostgreSQL (n8n) | `n8n` | interne uniquement | `http://postgres.n8n.svc.cluster.local:5432` | |
| Axtazia Bot | `bots` | `https://axtazia.mydomain2.fr/webhook/twitch` | `http://axtazia-bot.bots.svc.cluster.local:3000` | Webhook Twitch EventSub sur port 3000 |
| Authentik SSO | `authentik` | `https://auth.mydomain2.fr` | `http://authentik-server.authentik.svc.cluster.local:9000` | Provider SSO OIDC pour les autres apps |
| PostgreSQL (authentik) | `authentik` | interne uniquement | `http://postgresql.authentik.svc.cluster.local:5432` | |
| ntfy | `ntfy` | `https://ntfy.mydomain2.fr` | `http://ntfy.ntfy.svc.cluster.local:80` | Auth activée, `deny-all` par défaut |
| Matrix Synapse | `matrix` | `https://matrix.mydomain2.fr` | `http://synapse.matrix.svc.cluster.local:8008` | Homeserver privé, fédération fermée, inscriptions sur token uniquement (voir [Matrix](apps/matrix.md)), aperçus de liens (URL previews) activés avec blacklist IP anti-SSRF |
| PostgreSQL (matrix) | `matrix` | interne uniquement | `http://postgres.matrix.svc.cluster.local:5432` | |
| Matrix well-known | `matrix` | `https://matrix.mydomain2.fr/.well-known/matrix/client` | — | Sert la découverte du service LiveKit (MSC4143) |
| Draupnir | `matrix` | interne uniquement (bot) | — | Modération (bans propagés, listes communautaires, admin homeserver) — remplaçant maintenu de Mjolnir, voir [Matrix](apps/matrix.md) |
| Maubot | `matrix` | `https://maubot.mydomain2.fr/_matrix/maubot` | `http://maubot.matrix.svc.cluster.local:29316` | Bot à plugins — diffusion de flux RSS/Atom dans les salons (plugin `xyz.maubot.rss`), base SQLite sur le PVC, voir [Matrix](apps/matrix.md) |
| LiveKit (SFU Element Call) | `livekit` | `wss://livekit.mydomain2.fr` | `http://livekit-signaling.livekit.svc.cluster.local:7880` | Signaling via Cloudflare Tunnel ; média (UDP/TCP) relayé via tunnel WireGuard → VPS `203.0.113.10` (voir [LiveKit](apps/livekit.md)) |
| lk-jwt-service | `livekit` | `https://livekit-jwt.mydomain2.fr` | `http://lk-jwt-service.livekit.svc.cluster.local:8080` | Émet les jetons LiveKit pour Element Call, homeserver autorisé : `matrix.mydomain2.fr` |
| Panel admin (root) | `root-panel` | `https://root.mydomain2.fr` | `http://root-panel.root-panel.svc.cluster.local:8080` | Page statique de liens vers tous les panels d'admin (cluster, LAN, services externes) ; contenu dans le repo privé `Axtazer/root-panel` (hors miroir public), image GHCR privée ; à protéger par Cloudflare Access |
| cloudflare-tunnel-ingress-controller | `cloudflare-tunnel-ingress-controller` | — | — | Gère routes Cloudflare via Ingress K8s |
| **[archivé 2026-06-27]** AlterTrack | — | `https://altertrack.mydomain.fr` | — | Manifests dans `_archived/altertrack/` |
| **[archivé 2026-06-27]** PageBleue | — | `https://pagebleue.mydomain.fr` | — | Manifests dans `_archived/etudes/` |
| **[archivé 2026-07-05]** BetterStack collector | — | — | — | Manifests dans `_archived/betterstack-collector/` |
| **[archivé 2026-10-11]** media-share | — | — | — | Manifests et doc dans `_archived/media-share/` |
