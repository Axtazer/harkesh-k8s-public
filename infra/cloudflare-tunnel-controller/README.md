# cloudflare-tunnel-ingress-controller

Gère automatiquement les routes Cloudflare Tunnel via des ressources Ingress K8s (`ingressClassName: cloudflare-tunnel`).

## Fonctionnement

Le controller surveille les `Ingress` avec `ingressClassName: cloudflare-tunnel` et crée/supprime automatiquement les routes dans le tunnel Cloudflare + les records DNS.

```
Cloudflare Edge → cloudflared (géré par le controller) → Service K8s
```

## Prérequis 1Password

Créer dans le vault `k8s-home` un item `cloudflare-tunnel-controller` avec les champs :

| Champ | Valeur |
|---|---|
| `apiToken` | Token API Cloudflare (permissions : `Tunnel:Edit`, `DNS:Edit`, `Zone:Read`) |
| `accountId` | Account ID Cloudflare (visible dans l'URL du dashboard) |
| `tunnelName` | Nom du tunnel — créé automatiquement s'il n'existe pas |

## Créer un token API

1. Cloudflare Dashboard → My Profile → API Tokens → **Create Token**
2. Permissions requises :
   - `Account > Cloudflare Tunnel : Edit`
   - `Zone > DNS : Edit`
   - `Zone > Zone : Read`

## Ajouter une nouvelle route

Ajouter un `Ingress` avec `ingressClassName: cloudflare-tunnel` dans le manifest de l'app :

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mon-app-tunnel
  namespace: mon-namespace
spec:
  ingressClassName: cloudflare-tunnel
  rules:
    - host: mon-app.axtazer.me
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mon-app
                port:
                  number: 80
```

Le controller crée la route et le DNS automatiquement au prochain sync ArgoCD.
