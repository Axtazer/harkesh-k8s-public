[← Sommaire](README.md)

# Endpoints à monitorer

Liste des endpoints publics exposés via Cloudflare Tunnel et de leurs health checks internes, pour configuration des monitors externes.

## Critiques

| App | URL | Health endpoint | Vérification recommandée |
|---|---|---|---|
| mydomain2.fr | https://mydomain2.fr | `/` | code 200 |
| flo-pro (prod) | https://mydomain.fr | `/` | code 200 |
| authentik (SSO) | https://auth.mydomain2.fr | `/` | code 200 — dépendance transverse, si down bloque les apps derrière SSO |
| jellyfin | https://stream.mydomain2.fr | `/health` | texte `Healthy` |
| n8n | https://n8n.mydomain.fr | `/` | code 200 |
| nextcloud | https://nas.mydomain.fr | `/status.php` | JSON, assertion sur `"installed":true,"maintenance":false` (un 200 seul ne détecte pas le mode maintenance) |

## Media stack (namespace media)

| App | URL | Health endpoint | Vérification recommandée |
|---|---|---|---|
| prowlarr | https://prowlarr.mydomain2.fr | `/` | code 200 (endpoint riche `/api/v3/health` dispo avec clé API — cf. section Améliorations) |
| radarr | https://radarr.mydomain2.fr | `/` | code 200 (idem `/api/v3/health`) |
| sonarr | https://sonarr.mydomain2.fr | `/` | code 200 (idem `/api/v3/health`) |
| qbittorrent | https://qbit.mydomain2.fr | `/` | code 200 — surveille aussi indirectement le tunnel Gluetun VPN |
| jellyseerr | https://jellyseerr.mydomain2.fr | `/api/v1/settings/public` | code 200 |

## Secondaires

| App | URL | Health endpoint | Vérification recommandée |
|---|---|---|---|
| ntfy | https://ntfy.mydomain2.fr | `/v1/health` | JSON, assertion sur `"healthy":true` — critique car sert de canal d'alerting |
| shlink | https://shlink.mydomain2.fr | `/rest/health` | JSON, assertion sur `"status":"pass"` |
| shlink (go.mydomain2.fr) | https://go.mydomain2.fr | `/` | code 200 |
| pelican panel | https://panel.mydomain2.fr | `/` | code 200 (probe interne en TCP:80 uniquement, pas de check applicatif) |
| pelican wings | https://node01.mydomain2.fr | `/` | code 200 |
| grafana | https://grafana.mydomain.fr | `/` | code 200 — watchdog externe du stack de monitoring lui-même |
| axtazia (bot) | https://axtazia.mydomain2.fr | `/webhook/twitch` | code 200/401 selon signature — pas de health dédié |
| flo-pro (dev) | https://dev-pro.mydomain.fr | `/` | code 200 — priorité basse (environnement de dev) |

## Améliorations possibles

- **Sonarr / Radarr / Prowlarr** exposent un endpoint `/api/v3/health` renvoyant les warnings internes (indexer down, espace disque, etc.), mais nécessite le header `X-Api-Key`. Les clés sont dans les secrets `OnePasswordItem` (vault `k8s-home`) de chaque app — à récupérer si on veut un monitoring plus fin que la simple disponibilité HTTP.
- **Heartbeats** à envisager pour les jobs non-HTTP : workflow `update-image`, backups Nextcloud.
