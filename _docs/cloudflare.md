[← Sommaire](README.md)

# Cloudflare (zones, WAF, Access)

Configuration **hors dépôt** : tout ce qui suit vit dans le dashboard Cloudflare (compte « Axtazer », forfait
Free sur les 3 zones), pas dans les manifests. Cette page décrit l'état de référence pour pouvoir le
reconstruire ou comprendre un blocage. Le tunnel et ses routes, eux, sont gérés depuis le dépôt :
[Cloudflare Tunnel](cloudflare-tunnel.md).

État relevé le 2026-10-21 (après l'audit Cloudflare). Toute modification dans le dashboard doit être
reportée ici.

## Chemin d'une requête

```
Internet → Cloudflare (WAF → Access → cache) → tunnel HAR_K8S → cloudflared → Service K8s
                                             → tunnel VPS-Hermes → services du VPS
```

Aucun port entrant HTTP chez soi : le seul chemin est le tunnel. Exception hors Cloudflare : les ports
de jeu / SFTP (Pelican/Wings) exposés sur l'IP publique du domicile.

| Tunnel | Géré par | Services |
|---|---|---|
| `HAR_K8S` | `cloudflare-tunnel-ingress-controller` (Ingress du dépôt), 2 réplicas cloudflared | toutes les apps du cluster |
| `VPS-Hermes` | à la main, sur le VPS | `cal.mydomain2.fr`, `status.mydomain2.fr` (Uptime Kuma), `hermes-pc.mydomain.fr` |

## Réglages communs aux 3 zones

`mydomain2.fr`, `mydomain.fr`, `croissante.dev` sont alignées :

| Réglage | Valeur |
|---|---|
| SSL | Full (strict) |
| TLS minimum | 1.3 |
| HSTS | activé, `max-age` 1 jour, `nosniff`, **sans** `includeSubDomains` ni `preload` (passage à 6 mois prévu après le 2026-10-28 si rien n'a cassé) |
| Always Use HTTPS / Automatic HTTPS Rewrites | on |
| DNSSEC | actif (DS de `croissante.dev` publié chez le registrar, hors Cloudflare) |
| Rocket Loader | **off** (casse le JS d'ArgoCD, Grafana, n8n) |
| Hotlink protection | on |
| Bot Fight Mode | on (non contournable en Free : un `skip` de `http_request_sbfm` est sans effet) |
| Robots IA | bloqués, `robots.txt` géré par Cloudflare |
| Détection d'identifiants fuités | on + règle de rate limit `Leaked credential check` (5 req / 10 s par IP et colo) |
| Cache | niveau `aggressive` + règles « pas de cache » ci-dessous |

## WAF : règles personnalisées

Ordre d'évaluation de haut en bas ; un `skip` « ruleset current » saute **les règles personnalisées
suivantes**, dont le blocage géographique.

### Blocage géographique (les 3 zones)

```
block si : pays ∉ {BE, CA, FR, CH, AD} et pas cf.client.bot
```

- `cf.client.bot` = robots **vérifiés** par Cloudflare (Googlebot, Bingbot…) : nécessaire au référencement
  de `mydomain.fr` (flo-pro), `mydomain2.fr` et `croissante.dev`. Ne jamais remplacer par un test de
  User-Agent : un User-Agent se falsifie (c'était la faille principale de l'audit).
- Conséquence : depuis un autre pays, plus d'accès aux sites ni aux interfaces d'admin (le dashboard
  Cloudflare reste accessible pour corriger). Pour voyager : ajouter temporairement le pays dans **les 3
  règles** et dans le groupe Access des pays autorisés.

### Exceptions par zone

| Zone | Règle | Condition | Saute | Pourquoi |
|---|---|---|---|---|
| mydomain2.fr | `PASS \| Wings & Github & Shlink` | IP ∈ liste `$bbox` **ou** IP GitHub + chemin `/api/webhook` **ou** hôte `node01.mydomain2.fr` **ou** `go.mydomain2.fr/rest/v3/*` | règles perso suivantes, règles gérées, BIC | domicile ; webhooks GitHub ; Wings (le navigateur des joueurs et le panel s'y connectent) ; API Shlink (clé API exigée par Shlink) |
| mydomain2.fr | `Twitch Pass` | chemin `/webhook/twitch` et ASN 16509 (AWS) | règles gérées, rate limit, security level… | EventSub Twitch → bot Axtazia ; la signature Twitch est vérifiée par le bot (un POST non signé reçoit 403 du bot) |
| mydomain2.fr | (dans `Geo Block`) | hôte `axtazia.mydomain2.fr` + chemin `/webhook/twitch` exclus | — | Twitch appelle depuis les US |
| mydomain.fr | `PASS \| Github` | IP GitHub + chemin `/api/webhook` | règles perso suivantes, règles gérées | webhooks GitHub |

- **Liste `$bbox`** (compte, type IP) : l'IPv4 du domicile (Free) et son préfixe IPv6 `/64`. Contourne le
  blocage géographique et les règles gérées sur mydomain2.fr. **À mettre à jour si l'IP Free change** (ou
  après un changement de box/FAI : l'ancienne liste pointait encore sur des IP Bouygues réattribuées).
  IP actuelle : `curl -4 ifconfig.me` / `curl -6 ifconfig.me` depuis le domicile.
- **Webhooks n8n** (`n8n.mydomain.fr/webhook/*`) : publics côté Access, mais **soumis au blocage
  géographique**. Un service externe qui appelle depuis un autre pays sera bloqué : ajouter alors une
  exception WAF ciblée (chemin + ASN ou IP du service), sur le modèle de Twitch.

## Access (Zero Trust)

Fournisseur d'identité : **authentik** (OIDC, `auth.mydomain2.fr`, jamais derrière Access lui-même).
Sessions de 24 h.

### Politiques

| Politique | Décision | Règle | Applications |
|---|---|---|---|
| `Login` | allow | **include** e-mail du propriétaire **et require** connexion via authentik **et require** groupe « pays autorisés » (BE, CA, FR, CH, AD) | toutes les apps d'admin (13) |
| `Public — webhooks n8n` | bypass | tout le monde | `n8n webhooks (public)` |
| `Hermes-PC-AccessToken` | service auth | jeton de service `Hermes-PC` | `hermes-pc` |

Les règles `include` se combinent en **OU** : un pays ou un groupe en `include` n'est pas une
restriction. Les restrictions vont en `require`.

### Applications

| Application | Domaine | Politique |
|---|---|---|
| argocd | `argocd.mydomain.fr` | Login |
| grafana | `grafana.mydomain.fr` | Login |
| n8n | `n8n.mydomain.fr` | Login |
| n8n webhooks (public) | `n8n.mydomain.fr/webhook/*`, `/webhook-test/*` | bypass |
| Dev Flo-pro | `dev-pro.mydomain.fr` | Login |
| root | `root.mydomain2.fr` | Login |
| maubot | `maubot.mydomain2.fr` | Login |
| shlink | `shlink.mydomain2.fr` (client web ; l'API `go.mydomain2.fr` n'est pas derrière Access) | Login |
| prowlarr / radarr / sonarr / qbit | `*.mydomain2.fr` | Login |
| hermes-pc | `hermes-pc.mydomain.fr` (VPS) | jeton de service |
| App Launcher, Warp Login App | `axtazer.cloudflareaccess.com` | Login |
| SSO App | SSO du dashboard Cloudflare | ne pas toucher (méthode de connexion au compte) |

**Volontairement sans Access** (authentification propre, clients non navigateur ou public) :
`mydomain2.fr`, `mydomain.fr`, `croissante.dev`, `go.mydomain2.fr` (redirections), `auth.mydomain2.fr`,
`stream.mydomain2.fr` (Jellyfin : applis TV/mobile), `jellyseerr.mydomain2.fr`, `nas.mydomain.fr`
(Nextcloud : clients de synchro), `matrix.mydomain2.fr` / `livekit*.mydomain2.fr` (clients Matrix),
`ntfy.mydomain2.fr` (auth ntfy), `panel.mydomain2.fr` (joueurs, login Pelican), `node01.mydomain2.fr` (Wings),
`axtazia.mydomain2.fr` (webhook Twitch).

**Nouvelle interface d'admin exposée** → créer une application Access avec la politique `Login` dans la
même opération que l'Ingress.

## Cache et redirections

| Zone | Règle | Effet |
|---|---|---|
| mydomain2.fr | `No panel cache` | pas de cache sur `panel.mydomain2.fr` |
| mydomain2.fr | `Pas de cache — Jellyfin et Matrix` | pas de cache sur `stream` et `matrix` (vidéo via le CDN interdite par les CGU) |
| mydomain.fr | `Pas de cache — Nextcloud` | pas de cache sur `nas.mydomain.fr` |
| mydomain.fr | `www → apex` | 301 `www.mydomain.fr` → `mydomain.fr` (chemin et paramètres conservés) |
| mydomain.fr | `HTTP/HTTPS Linkedin` | 302 `pro.mydomain.fr` → profil LinkedIn |
| croissante.dev | `www → apex` | 301 `www.croissante.dev` → `croissante.dev` |

`mydomain.fr` applique aussi la normalisation des URL vers l'origine (pas les deux autres zones) :
laissé tel quel, cela changerait les URL reçues par Nextcloud et flo-pro.

## Notifications Cloudflare

Par e-mail : santé des tunnels `HAR_K8S` + `VPS-Hermes`, attaque DDoS HTTP, plus les 3 notifications par
défaut (budget, analytics, image resizing). Les alertes de l'infra elle-même passent par Grafana → ntfy
([Monitoring](monitoring.md)).

## Vérifications

Depuis le domicile (IP dans `$bbox`) ou un réseau français :

```bash
for h in argocd.mydomain.fr grafana.mydomain.fr n8n.mydomain.fr dev-pro.mydomain.fr root.mydomain2.fr \
         maubot.mydomain2.fr prowlarr.mydomain2.fr radarr.mydomain2.fr sonarr.mydomain2.fr qbit.mydomain2.fr \
         shlink.mydomain2.fr; do
  printf "%-24s " $h; curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://$h/
done
```

Chaque ligne doit être un `302` vers `…cloudflareaccess.com/cdn-cgi/access/login/…`. Un `200` ou une
redirection vers la page de login de l'app = application Access manquante.

Depuis un pays hors liste (VPN), tout doit répondre `403`, y compris avec un faux User-Agent :

```bash
curl -s -o /dev/null -w '%{http_code}\n' -A 'Googlebot/2.1 (+http://www.google.com/bot.html)' https://mydomain2.fr/
```

Événements de sécurité : dashboard → zone → Security → Events (24 h en Free).

## Historique

- **2026-10-21 — audit Cloudflare** : suppression du contournement par User-Agent (Googlebot / Better
  Stack ouvraient le blocage géographique et les règles gérées), politique Access `Login` passée en
  e-mail + authentik + pays en `require`, Access ajouté sur Grafana et n8n, panel Pelican soumis au
  blocage géographique et aux règles gérées, liste `$bbox` corrigée (anciennes IP Bouygues), SSL Full
  (strict), HSTS, DNSSEC sur croissante.dev, alignement des 3 zones, Rocket Loader off, cache désactivé
  sur Jellyfin/Matrix/Nextcloud, redirections `www`, `fbx.mydomain.fr` supprimé, certificat d'origine
  `*.mydomain.fr` révoqué (inutile derrière les tunnels), notifications tunnels + DDoS, ménage des règles
  mortes.
