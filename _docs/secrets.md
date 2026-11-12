[← Sommaire](README.md)


# Secrets

Tous les secrets sont dans le vault `k8s-home` sur 1Password et injectés automatiquement par le **1Password Connect Operator** via les `OnePasswordItem` définis dans chaque manifest. Connect + operator sont déployés par ArgoCD (`argocd/onepassword-connect.yaml`) ; seuls leurs deux Secrets d'accès sont créés à la main (cf. [reinstallation.md](reinstallation.md), étape 3).

| Item 1Password | Secret K8s | Namespace |
|---|---|---|
| `nextcloud-db` | `nextcloud-db-secret` | `nextcloud` |
| `axtazia-bot` | `axtazia-secrets` | `bots` |
| `cloudflare-tunnel-controller` | `cloudflare-tunnel-controller` | `cloudflare-tunnel-ingress-controller` |
| `flo-pro-env` | `flo-pro-env` | `flo-pro` |
| `dev-flo-pro-env` | `dev-flo-pro-env` | `flo-pro` (dev uniquement) |
| `shlink` | `shlink-secrets` | `shlink` |
| `shlink-db` | `shlink-db-secret` | `shlink` |
| `axtazer-me` | `axtazer-secrets` | `axtazer-me` |
| `grafana-admin` | `grafana-admin` | `monitoring` |
| `cloudflare-analytics-token` | `cloudflare-analytics-token` | `monitoring` |
| `grafana-ntfy-token` | `grafana-ntfy-token` | `monitoring` |
| `n8n` | `n8n-secrets` | `n8n` |
| `n8n-db` | `n8n-db-secrets` | `n8n` |
| `mullvad-credentials` | `mullvad-credentials` | `media` |
| `authentik` | `authentik-secret` | `authentik` |
| `matrix` | `matrix-secrets` | `matrix` |
| `draupnir` | `draupnir-secrets` | `matrix` |
| `maubot` | `maubot-secrets` | `matrix` |
| `livekit` | `livekit-secrets` | `livekit` |

# Secrets gérés manuellement

Certains secrets ne peuvent pas être gérés via 1Password Connect Operator
car celui-ci ne supporte pas le type `kubernetes.io/dockerconfigjson` (bug #95).

## ghcr-secret

À recréer manuellement après chaque réinstallation dans chaque namespace qui utilise des images GHCR privées :

```bash
for ns in bots axtazer-me flo-pro root-panel alchimie-creatures; do
  kubectl create secret docker-registry ghcr-secret \
    --docker-server=ghcr.io \
    --docker-username=Axtazer \
    --docker-password=GHCR_TOKEN \
    -n $ns
done
```

Le token GHCR est stocké dans 1Password → vault `k8s-home` → item `ghcr-token`.
