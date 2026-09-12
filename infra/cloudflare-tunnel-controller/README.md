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

## Dépannage

### `Authentication error (10000)` au démarrage

```
main: "msg"="bootstrap tunnel client with tunnel name"
      "error"="get tunnel id from tunnel name HAR_K8S: list cloudflare tunnels: Authentication error (10000)"
```

Le nom du tunnel s'affiche dans le log : le Secret est donc bien monté et les trois clés
(`apiToken`, `accountId`, `tunnelName`) existent — sinon le pod ne démarrerait même pas
(`CreateContainerConfigError`). C'est Cloudflare qui rejette le token sur
`GET /accounts/<accountId>/cfd_tunnel`. Rien à corriger côté manifests : la cause est dans
l'item 1Password ou dans le token lui-même.

Causes possibles, par ordre de fréquence :

1. Token expiré ou révoqué côté Cloudflare ;
2. Permission `Account > Cloudflare Tunnel : Edit` absente du token ;
3. Token émis pour un autre compte que la valeur du champ `accountId` ;
4. Espace ou retour à la ligne parasite dans le champ `apiToken` de l'item 1Password ;
5. Token déjà corrigé dans 1Password mais pod non redémarré — les variables d'environnement
   sont figées au démarrage du conteneur, la resynchronisation du Secret par l'operator ne
   suffit pas.

Diagnostic (aucune de ces commandes n'affiche le token) :

```bash
NS=cloudflare-tunnel-ingress-controller
TOKEN=$(kubectl -n $NS get secret cloudflare-tunnel-controller -o jsonpath='{.data.apiToken}' | base64 -d)
ACCOUNT=$(kubectl -n $NS get secret cloudflare-tunnel-controller -o jsonpath='{.data.accountId}' | base64 -d)

# Aucun caractère parasite attendu (0) — la longueur d'un token n'est pas fiable comme indice
printf '%s' "$TOKEN" | grep -cP '[^A-Za-z0-9._-]'

# Le token est-il encore valide ? (cause 1)
curl -s -H "Authorization: Bearer $TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq '.success, .errors'

# Le token a-t-il le droit de lister les tunnels de ce compte ? (causes 2 et 3)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/cfd_tunnel?is_deleted=false" | jq '.success, .errors'
```

- `verify` KO → token invalide/expiré/révoqué : en régénérer un (permissions ci-dessus) et
  mettre à jour le champ `apiToken` de l'item `cloudflare-tunnel-controller` (vault `k8s-home`) ;
- `verify` OK mais `cfd_tunnel` KO → le token est valide mais n'a pas accès à ce compte :
  permission `Account > Cloudflare Tunnel : Edit` manquante (cause 2) ou `accountId` qui ne
  correspond pas au compte du token (cause 3). Ce `curl` reproduit exactement l'appel qui fait
  échouer le controller — s'il passe alors que le pod échoue encore, c'est que le pod tourne
  avec une ancienne valeur (cause 5).

Pour distinguer les causes 2 et 3, comparer les comptes visibles par le token avec l'`accountId`
du Secret :

```bash
echo "accountId dans le Secret : $ACCOUNT"
curl -s -H "Authorization: Bearer $TOKEN" \
  https://api.cloudflare.com/client/v4/accounts | jq '.success, [.result[]? | {id, name}], .errors'
```

- un compte listé dont l'`id` diffère de `$ACCOUNT` → cause 3 : corriger le champ `accountId` ;
- l'`id` correspond, ou la liste est vide / `success: false` → cause 2 : le token n'a aucune
  permission de niveau Account. Éditer le token dans le dashboard Cloudflare pour lui ajouter
  `Account > Cloudflare Tunnel : Edit`, en vérifiant que « Account Resources » cible bien ce compte.

Après correction dans 1Password, forcer la relecture du Secret par le pod :

```bash
kubectl -n cloudflare-tunnel-ingress-controller rollout restart \
  deploy/cloudflare-tunnel-controller-cloudflare-tunnel-ingress-controller
kubectl -n cloudflare-tunnel-ingress-controller logs -l app.kubernetes.io/name=cloudflare-tunnel-ingress-controller -f
```

Pendant l'incident, le connecteur `controlled-cloudflared-connector` déjà déployé continue de
tourner avec sa configuration : le trafic des routes existantes passe toujours, seules les
créations/suppressions de routes et de records DNS sont bloquées.
