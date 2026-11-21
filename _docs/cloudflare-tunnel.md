[← Sommaire](README.md)

# cloudflare-tunnel-ingress-controller

Gère automatiquement les routes Cloudflare Tunnel via des ressources Ingress K8s (`ingressClassName: cloudflare-tunnel`).
WAF, Access et réglages des zones (hors dépôt) : [Cloudflare](cloudflare.md).

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
    - host: mon-app.mydomain2.fr
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

Le controller crée la route et le DNS automatiquement au prochain sync ArgoCD. Interface d'admin →
la mettre derrière Access (politique `Login`) dans la foulée : [Cloudflare](cloudflare.md#access-zero-trust).

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

> **Cause déjà rencontrée (2026-09) : le filtrage IP du token.**
> Le token Cloudflare porte une restriction *Client IP Address Filtering* et l'IP publique
> du cluster a changé (changement d'opérateur, de box, ou simplement IP dynamique renouvelée).
> Le token reste valide et correctement permissionné, mais tous ses appels sont refusés en 10000.
> Piège : `/user/tokens/verify` répond quand même `success: true` — le filtre IP ne se voit
> donc **pas** sur `verify`, seulement sur les appels réels comme `/accounts/…/cfd_tunnel`.
> Correction : dashboard Cloudflare → My Profile → API Tokens → le token → Edit →
> « Client IP Address Filtering ». Y mettre la nouvelle IP publique, ou retirer la restriction
> si l'IP n'est pas fixe.

Causes possibles :

1. Filtrage IP du token et IP publique du cluster changée (voir encadré ci-dessus) ;
2. Token expiré ou révoqué côté Cloudflare ;
3. Permission `Account > Cloudflare Tunnel : Edit` absente du token ;
4. Token émis pour un autre compte que la valeur du champ `accountId` ;
5. Espace ou retour à la ligne parasite dans le champ `apiToken` de l'item 1Password ;
6. Token déjà corrigé mais pod non redémarré — les variables d'environnement sont figées au
   démarrage du conteneur, la resynchronisation du Secret par l'operator ne suffit pas.

Diagnostic (aucune de ces commandes n'affiche le token) :

```bash
NS=cloudflare-tunnel-ingress-controller
TOKEN=$(kubectl -n $NS get secret cloudflare-tunnel-controller -o jsonpath='{.data.apiToken}' | base64 -d)
ACCOUNT=$(kubectl -n $NS get secret cloudflare-tunnel-controller -o jsonpath='{.data.accountId}' | base64 -d)

# IP publique vue par Cloudflare — à comparer avec le filtre IP du token (cause 1)
curl -s https://cloudflare.com/cdn-cgi/trace | grep '^ip='

# Aucun caractère parasite attendu (0) — la longueur d'un token n'est pas fiable comme indice
printf '%s' "$TOKEN" | grep -cP '[^A-Za-z0-9._-]'

# Le token existe-t-il encore ? (cause 2) — attention : ce test ignore le filtrage IP
curl -s -H "Authorization: Bearer $TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq '.success, .errors'

# L'appel qui fait réellement échouer le controller (causes 1, 3 et 4)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/cfd_tunnel?is_deleted=false" | jq '.success, .errors'
```

- `verify` KO → token révoqué ou supprimé : en régénérer un (permissions ci-dessus) et
  mettre à jour le champ `apiToken` de l'item `cloudflare-tunnel-controller` (vault `k8s-home`) ;
- `verify` OK mais `cfd_tunnel` KO → **commencer par le filtrage IP** (cause 1), c'est le seul cas
  qui produit cette combinaison sans qu'aucune configuration n'ait bougé ; sinon permission
  `Account > Cloudflare Tunnel : Edit` manquante (cause 3) ou `accountId` d'un autre compte
  (cause 4). Ce `curl` reproduit exactement l'appel du controller — s'il passe alors que le pod
  échoue encore, c'est que le pod tourne avec une ancienne valeur (cause 6) ;
- les deux OK → il ne reste que la cause 6, redémarrer le pod.

Pour départager les causes 3 et 4, comparer les comptes visibles par le token avec l'`accountId`
du Secret :

```bash
echo "accountId dans le Secret : $ACCOUNT"
curl -s -H "Authorization: Bearer $TOKEN" \
  https://api.cloudflare.com/client/v4/accounts | jq '.success, [.result[]? | {id, name}], .errors'
```

- un compte listé dont l'`id` diffère de `$ACCOUNT` → cause 4 : corriger le champ `accountId` ;
- l'`id` correspond, ou la liste est vide / `success: false` → cause 3 : le token n'a aucune
  permission de niveau Account. Éditer le token dans le dashboard Cloudflare pour lui ajouter
  `Account > Cloudflare Tunnel : Edit`, en vérifiant que « Account Resources » cible bien ce compte.

Après correction (dans 1Password ou sur le token Cloudflare), redémarrer le pod — utile même
quand la valeur du Secret n'a pas changé, pour ne pas attendre le backoff du `CrashLoopBackOff` :

```bash
kubectl -n cloudflare-tunnel-ingress-controller rollout restart \
  deploy/cloudflare-tunnel-controller-cloudflare-tunnel-ingress-controller
kubectl -n cloudflare-tunnel-ingress-controller logs -l app.kubernetes.io/name=cloudflare-tunnel-ingress-controller -f
```

Pendant l'incident, le connecteur `controlled-cloudflared-connector` déjà déployé continue de
tourner avec sa configuration : le trafic des routes existantes passe toujours, seules les
créations/suppressions de routes et de records DNS sont bloquées.

### Bruit dans le journal d'audit Cloudflare

Symptôme : le journal d'audit du compte (`/accounts/<id>/logs/audit`) est rempli par le token du
controller (« Cloudflare Tunel K8S », user-agent `cloudflare-go/v4`) et les vrais changements (WAF,
Access, DNS manuels) y sont noyés.

Mesuré le 2026-11-16 sur trois jours de journal (≈ 35 500 événements, dont 17 écritures qui ne
viennent pas du controller) :

| Événement | Volume | Origine dans le code du controller |
|---|---|---|
| `Get a Cloudflare Tunnel token` | 1 toutes les 10 s, ≈ 8 640 / jour | boucle de réconciliation du connecteur `controlled-cloudflared-connector` : minuterie de 10 s écrite en dur, qui relit le token du tunnel à chaque tour |
| `Update DNS Record` | rafales de 1 536, toutes les ~10 h 30, ≈ 3 300 / jour | voir ci-dessous |
| `Get Tunnel configuration` / `List DNS Records` | 24 / 144 par rafale | une lecture de la config et deux listes (CNAME, TXT) par zone, à chaque réconciliation |
| `Update Tunnel configuration` | seulement lors d'un vrai changement d'Ingress | la config du tunnel, elle, est comparée avant écriture |

Cause des `Update DNS Record` — trois comportements du controller qui se multiplient :

1. **Réécriture inconditionnelle.** À chaque réconciliation, tout enregistrement existant (le CNAME
   de chaque hôte **et** son TXT de propriété `_ctic_managed.<hôte>`) est renvoyé à Cloudflare, sans
   comparer avec ce qui est déjà en place. Les enregistrements sont pourtant déjà identiques
   (contenu, proxy, TTL, commentaire) : ce sont des écritures à blanc.
2. **Chaque Ingress resynchronise tous les hôtes.** La réconciliation d'un Ingress recalcule et
   repousse l'ensemble des expositions, pas seulement les siennes.
3. **Resynchronisation périodique complète.** Le cache du controller (controller-runtime) rejoue
   tous les Ingress toutes les ~10 h (valeur par défaut, non exposée), ainsi qu'à chaque
   redémarrage du pod.

D'où, par rafale : `nombre d'Ingress × 2 × nombre d'hôtes` écritures (24 × 2 × 32 = 1 536 au moment
de la mesure). Le volume croît donc au carré du nombre d'apps exposées.

Ce que ce n'est **pas** : il n'y a qu'un seul réplica du controller (`replicaCount: 1`, et les
appels token tombent exactement toutes les 10 s — deux réplicas en feraient le double ; les
réconciliations d'une rafale se suivent une à une, à ~20 s d'intervalle). Les deux
`Update Tunnel configuration` vus à la même minute correspondent à un vrai changement (suppression
d'Ingress), traité en deux réconciliations successives.

Rien de tout cela n'est réglable par les values du chart : pas d'option d'intervalle de
resynchronisation, la minuterie de 10 s est en dur, et la leader election ne change rien avec un
seul réplica. À la date de la mesure, aucune version publiée du chart ne corrige la réécriture
inconditionnelle (le code est identique sur la branche principale upstream). Le correctif est côté
upstream : ne pas envoyer la mise à jour quand l'enregistrement est déjà conforme — signalé dans
[STRRL/cloudflare-tunnel-ingress-controller#377](https://github.com/STRRL/cloudflare-tunnel-ingress-controller/issues/377).
Une fois publié, il arrive par la montée de version du chart
(`argocd/cloudflare-tunnel-controller.yaml`, Renovate).

En attendant, **lire le journal d'audit en excluant le token du controller** — le filtre se fait
côté API, le bruit n'est jamais téléchargé (token avec `Account Settings : Read`) :

```bash
# Écritures des dernières 24 h qui ne viennent PAS du controller (les vrais changements)
curl -s -G "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/logs/audit" \
  -H "Authorization: Bearer $AUDIT_TOKEN" \
  --data-urlencode "since=$(date -u -d '24 hours ago' +%FT%TZ)" \
  --data-urlencode "before=$(date -u +%FT%TZ)" \
  --data-urlencode "actor_token_name.not=Cloudflare Tunel K8S" \
  --data-urlencode "action_type.not=view" \
  --data-urlencode "limit=1000" \
  | jq -r '.result[] | [.action.time, .action.description, (.actor.email // .actor.type), .raw.uri] | @tsv'
```

Compter les `Update DNS Record` du controller sur 24 h (à refaire après une montée de version du
chart pour vérifier que le correctif est là — attendu : proche de 0 hors changement d'Ingress, au
lieu de ≈ 3 300) :

```bash
SINCE=$(date -u -d '24 hours ago' +%FT%TZ); BEFORE=$(date -u +%FT%TZ); CURSOR=""; TOTAL=0
while :; do
  PAGE=$(curl -s -G "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/logs/audit" \
    -H "Authorization: Bearer $AUDIT_TOKEN" \
    --data-urlencode "since=$SINCE" --data-urlencode "before=$BEFORE" \
    --data-urlencode "actor_token_name=Cloudflare Tunel K8S" \
    --data-urlencode "resource_product=dns_records" \
    --data-urlencode "action_type=update" \
    --data-urlencode "limit=1000" ${CURSOR:+--data-urlencode "cursor=$CURSOR"})
  N=$(jq '.result | length' <<<"$PAGE"); TOTAL=$((TOTAL + N))
  CURSOR=$(jq -r '.result_info.cursor // empty' <<<"$PAGE")
  [ "$N" -eq 0 ] || [ -z "$CURSOR" ] && break
done
echo "Update DNS Record du controller sur 24 h : $TOTAL"
```

Ne pas contourner le problème avec l'annotation `disable-dns-management` sur les Ingress : le
controller **supprime** alors les CNAME qu'il possède (coupure des sites) et le DNS sort du GitOps.

### Micro-coupures de tous les sites (QUIC)

Symptôme : le monitoring externe voit tous les endpoints tomber ensemble quelques secondes,
plusieurs fois par heure ; les logs du connecteur montrent les 4 connexions qui tombent dans
la même seconde :

```
ERR failed to accept incoming stream requests error="failed to accept QUIC stream: timeout: no recent network activity"
```

Cause : le chemin UDP sortant (box/NAT) perd le flux QUIC (UDP 7844). Le connecteur est donc
forcé en HTTP/2 sur TCP 7844 (`cloudflared.protocol: http2` dans `values.yaml`). Vérifier après
déploiement :

```bash
kubectl -n cloudflare-tunnel-ingress-controller logs deploy/controlled-cloudflared-connector \
  | grep -E "Registered tunnel connection|protocol="   # doit afficher protocol=http2
```
