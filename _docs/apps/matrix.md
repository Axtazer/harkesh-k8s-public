[← Sommaire](../README.md)

# Matrix

Synapse, bots Draupnir et Maubot : procédures d'exploitation. Manifests dans [`matrix/`](../../matrix/).


## Matrix — générer un token d'inscription

**État actuel** : inscriptions sur token uniquement (`registration_requires_token: true`,
`enable_registration_without_verification: false` dans `matrix/matrix.yaml`) — sans token,
Element refuse l'inscription. Les comptes existants ne sont pas concernés.
Un compte admin (créé via `register_new_matrix_user -a`) est nécessaire pour générer un token.

```bash
# 1. Login pour récupérer un access_token (mot de passe saisi sans écho, jamais en clair dans l'historique)
read -s -p "Password admin: " ADMIN_PASSWORD; echo
ACCESS_TOKEN=$(curl -s https://matrix.mydomain2.fr/_matrix/client/v3/login \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"axtazer\"},\"password\":\"${ADMIN_PASSWORD}\"}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
unset ADMIN_PASSWORD

# 2. Créer un token (ici : 5 utilisations max, sans expiration — ajuster selon besoin)
curl -s -X POST https://matrix.mydomain2.fr/_synapse/admin/v1/registration_tokens/new \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d '{"uses_allowed": 5, "expiry_time": null}'
```

Le champ `"token"` de la réponse est à donner aux personnes invitées — elles le collent dans
Element au moment de l'inscription (`matrix.mydomain2.fr` comme homeserver).

## Draupnir — créer le compte bot

Draupnir a besoin d'un compte Matrix dédié pour agir en tant que modérateur.

```bash
# 1. Créer le compte (sur le pod synapse). Ajouter -a pour un compte admin homeserver
#    si tu veux utiliser les fonctions de modération au niveau serveur (suspension de
#    compte, blocage d'invitations, etc. — voir doc Draupnir "homeserver-administration").
kubectl exec -it -n matrix deploy/synapse -- register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008

# 2. Login pour récupérer l'access_token (mot de passe saisi sans écho)
read -s -p "Password draupnir: " BOT_PASSWORD; echo
curl -s https://matrix.mydomain2.fr/_matrix/client/v3/login \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"draupnir\"},\"password\":\"${BOT_PASSWORD}\"}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
unset BOT_PASSWORD
```

Mettre le token obtenu dans le champ `access-token` de l'item 1Password `draupnir`
(vault `k8s-home`). Au premier démarrage, Draupnir crée son salon de gestion et invite
le compte défini dans `initialManager` (`@axtazer:matrix.mydomain2.fr`) — c'est dans ce
salon que les commandes `!draupnir ...` se tapent.

## Maubot — créer le compte bot et diffuser des flux RSS

Maubot est un framework de bots Matrix à plugins ; le plugin officiel `xyz.maubot.rss`
poste les nouvelles entrées d'un flux RSS/Atom dans les salons abonnés. Le serveur est
déployé par GitOps (`matrix/maubot.yaml`), mais **le plugin et l'instance s'installent une
fois via l'interface web** — ils sont ensuite persistés sur le PVC
(`/srv/appdata/matrix/maubot`) et survivent aux redémarrages.

**1. Secrets** — créer l'item `maubot` dans le vault `k8s-home` avec deux champs générés
en hexadécimal (ils sont injectés par `sed` dans le template de config, donc pas de
caractère spécial) :

```bash
openssl rand -hex 32   # -> champ admin-password (login de l'interface web)
openssl rand -hex 32   # -> champ unshared-secret (signature des jetons d'API)
```

**2. Compte Matrix du bot** — même procédure que Draupnir, mais **sans** `-a` : le bot RSS
n'a besoin d'aucun droit d'administration sur le homeserver.

```bash
kubectl exec -it -n matrix deploy/synapse -- register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008
# utilisateur : rss   |   admin : no
```

**3. Interface web** — `https://maubot.mydomain2.fr/_matrix/maubot` (la racine `/` renvoie
404, c'est normal : l'UI est servie sous `ui_base_path`). Login **`axtazer`** + `admin-password`
— pas `root` : cet utilisateur ne peut jamais se connecter par mot de passe
(`check_password()` le refuse d'emblée), il n'existe que pour les jetons signés du CLI `mbc`.
⚠️ Cette interface donne un contrôle total sur le bot et sur les comptes Matrix qui y sont
connectés : la protéger par une policy **Cloudflare Access** comme les autres interfaces
d'admin.

**4. Client** — le formulaire de client de maubot 0.6 ne propose pas de login par mot de
passe (il n'a que `User ID`, `Homeserver`, `Access token`, `Device ID`…), il faut donc
récupérer un access_token comme pour Draupnir :

```bash
read -s -p "Password rss: " BOT_PASSWORD; echo
curl -s https://matrix.mydomain2.fr/_matrix/client/v3/login \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"rss\"},\"password\":\"${BOT_PASSWORD}\",\"initial_device_display_name\":\"maubot\"}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("access_token:", d["access_token"]); print("device_id: ", d["device_id"])'
unset BOT_PASSWORD
```

Puis dans l'UI, `Clients` → `+` : *User ID* `@rss:matrix.mydomain2.fr`, *Homeserver*
`matrix.mydomain2.fr` (entrée de la liste, elle pointe sur le Service interne
`synapse.matrix.svc.cluster.local:8008`), *Access token* et *Device ID* relevés ci-dessus,
puis **Sync**, **Autojoin** et **Enabled** activés — sans `Sync` le bot ne reçoit aucune
commande, sans `Autojoin` il n'accepte pas les invitations. Un display name et un avatar au
passage évitent un bot anonyme dans les salons.

**5. Plugin** — télécharger le `.mbp` de la dernière release du plugin RSS
(`xyz.maubot.rss-vX.Y.Z.mbp`, depuis <https://mau.dev/maubot/rss/-/releases> ou le miroir
<https://github.com/maubot/rss/releases>), puis dans l'UI : `Plugins` → `+` → uploader le
fichier. Le `.mbp` est stocké dans `/data/plugins` sur le PVC.

**6. Instance** — `Instances` → `+` : ID `rss`, *Primary user* = le client créé à
l'étape 4, *Type* = `xyz.maubot.rss`. Dans la config de l'instance (YAML à droite) :

```yaml
update_interval: 60          # minutes entre deux relevés des flux
command_prefix: "rss"        # commandes: !rss ...
notification_template: "New post in $feed_title: [$title]($link)"
allow_filter: false          # filtres regex réservés aux admins ci-dessous
admins:
- "@axtazer:matrix.mydomain2.fr"
```

**7. Utilisation** — inviter `@rss:matrix.mydomain2.fr` dans un salon, puis :

```text
!rss subscribe https://exemple.com/feed.xml   # abonner le salon (alias: !rss sub)
!rss subscriptions                            # lister les abonnements du salon
!rss unsubscribe <feed ID>                    # désabonner
!rss notice <feed ID> false                   # poster en message normal plutôt qu'en m.notice
!rss template <feed ID> <template>            # modèle de message ($feed_title, $title, $link, $summary, $date)
```

Par défaut, seuls les utilisateurs listés dans `admins` (config de l'instance) ou disposant
d'un niveau de pouvoir ≥ 50 dans le salon peuvent gérer les abonnements.

**Dépannage** — `kubectl logs -n matrix deploy/maubot` (logs sur stdout, pas de fichier).
Un flux qui ne remonte rien est en général un DROP réseau : les plages IP privées sont
bloquées en egress (anti-SSRF), donc un flux servi depuis le LAN ne fonctionnera pas —
vérifier avec
`kubectl exec -n kube-system ds/cilium -- hubble observe -n matrix --verdict DROPPED --follow`.
