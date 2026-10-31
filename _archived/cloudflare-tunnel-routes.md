# Routes tunnel Cloudflare archivées

Routes supprimées lors de l'archivage de altertrack et pagebleue.
À supprimer manuellement dans Zero Trust → Networks → Tunnels.

| # | Hostname | Path | Service interne | Priorité |
|---|---|---|---|---|
| 14 | `pagebleue.mydomain.fr` | `*` | `http://pagebleue.etudes.svc.cluster.local:80` | 0 |
| 15 | `altertrack.mydomain.fr` | `^/api/*` | `http://altertrack-backend.altertrack.svc.cluster.local:3001` | 0 |
| 16 | `altertrack.mydomain.fr` | `*` | `http://altertrack-frontend.altertrack.svc.cluster.local:80` | — |
