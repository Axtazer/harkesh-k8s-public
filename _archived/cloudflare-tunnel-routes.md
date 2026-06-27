# Routes tunnel Cloudflare archivées

Routes supprimées lors de l'archivage de altertrack et pagebleue.
À supprimer manuellement dans Zero Trust → Networks → Tunnels.

| # | Hostname | Path | Service interne | Priorité |
|---|---|---|---|---|
| 14 | `pagebleue.castaldo.fr` | `*` | `http://pagebleue.etudes.svc.cluster.local:80` | 0 |
| 15 | `altertrack.castaldo.fr` | `^/api/*` | `http://altertrack-backend.altertrack.svc.cluster.local:3001` | 0 |
| 16 | `altertrack.castaldo.fr` | `*` | `http://altertrack-frontend.altertrack.svc.cluster.local:80` | — |
