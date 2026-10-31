# Documentation harkesh

Documentation d'exploitation du cluster, rangée par sujet. Les manifests restent la référence
(versions, valeurs exactes) : ces pages expliquent le *pourquoi* et les procédures.

## Vue d'ensemble

| Page | Contenu |
|---|---|
| [Architecture réseau](architecture.md) | Chemin d'entrée unique (Cloudflare Tunnel), Gateway Cilium, NetworkPolicies, accès de secours |
| [Services](services.md) | Toutes les apps : URL publiques, adresses internes, notes |
| [Sécurité](securite.md) | Vue d'ensemble des protections (hôte, réseau, pods, API, secrets) |
| [Secrets](secrets.md) | Items 1Password ↔ Secrets K8s, secrets créés à la main (`ghcr-secret`) |

## Exploitation

| Page | Contenu |
|---|---|
| [Backup](backup.md) | Sauvegardes restic → Hetzner Storage Box : mise en place, vérification, restauration |
| [Hôte](hote.md) | Configuration de `harkesh` hors GitOps : DNS, kubelet, chiffrement etcd, CrowdSec, mises à jour système et Kubernetes |
| [Monitoring](monitoring.md) | Grafana, dashboards générés, alertes → ntfy |
| [Endpoints à surveiller](endpoints.md) | URLs et health checks pour les monitors externes |
| [Renovate](renovate.md) | Stratégie de mise à jour par image (automerge / manuel) |
| [Cloudflare Tunnel](cloudflare-tunnel.md) | Controller d'Ingress, ajout de routes, dépannage |
| [Cloudflare](cloudflare.md) | Config hors dépôt : réglages des zones, WAF (blocage géographique, exceptions), Access, cache |
| [Réinstallation complète](reinstallation.md) | Reconstruire le cluster de zéro, étape par étape |

## Applications

| Page | Contenu |
|---|---|
| [Matrix](apps/matrix.md) | Tokens d'inscription, bots Draupnir et Maubot |
| [LiveKit](apps/livekit.md) | Relais média via VPS WireGuard (Element Call) |
| [Media stack](apps/media-stack.md) | *arr, qBittorrent + Gluetun, stockage, VPN, dépannage |

## Archives

| Page | Contenu |
|---|---|
| [Migration vmctl](archives/vmctl-migration.md) | Import de l'historique Prometheus dans VictoriaMetrics (migration terminée, conservé pour référence) |

---

Convention : une app ou un composant qui a une procédure propre (création de compte, relais réseau,
dépannage récurrent) a sa page dans `apps/` ; le reste va dans la page du sujet concerné.
