# media-share (archivé 2026-10-11)

Section retirée du README principal à l'archivage, conservée pour référence.

## media-share — partage croisé de bibliothèque avec un pair

Jellyfin **n'a aucune fédération** : rien nativement pour agréger la bibliothèque d'un
autre serveur. `media-share/` implémente le seul montage propre — un tunnel WireGuard
point à point, chacun exposant son répertoire média en lecture seule, chacun ajoutant
celui de l'autre comme bibliothèque supplémentaire via des fichiers `.strm`.

```
              pod media-share (netns isolé)
  ┌──────────────────────────────────────────────────┐
  │ gluetun          wg0 ──► Mullvad (FR/CH)         │──► sortie Mullvad
  │ wg-tunnel        wg1 = 10.20.0.1/32 ═════════════╪══► pair 10.20.0.2
  │ sws (scratch)    10.20.0.1:8080  /media en RO    │    (chiffré e2e)
  │ proxy (nginx)    :8081 ──► 10.20.0.2:8080        │
  └──────────────────────────────────────────────────┘
            ▲                          │
    jellyfin│                          │ CronJob strm-sync (toutes les 6 h)
            └── lit /remote/<pair>/*.strm ◄─┘
```

Le pair voit une **IP de sortie Mullvad**, jamais l'IP résidentielle ; Mullvad ne
transporte que des paquets WireGuard opaques. Pas de VPS relais, contrairement à
LiveKit : en hub-and-spoke le VPS déchiffre et rechiffre, donc il voit tout, et faire
transiter des To de vidéo par lui plafonne le débit.

**Isolation — ce qui garantit quoi**

| Garantie | Mécanisme |
|---|---|
| Le pair ne peut rien écrire | `hostPath readOnly` + binaire sans code d'écriture (POST/PUT/DELETE → 405) + `runAsUser 1000` + `drop: ALL` |
| Le pair ne joint que le serveur de fichiers | `allowed-ips 10.20.0.2/32` (ACL cryptographique) + `iptables -i wg1` (ACCEPT 8080, DROP le reste) |
| Aucun shell à compromettre côté tunnel | image `scratch` : le layer ne contient que le binaire statique |
| Rien à écrire nulle part | `readOnlyRootFilesystem` sans aucun volume inscriptible sur `sws` |
| Le shell du sidecar WireGuard reste hors d'atteinte | mount + PID namespaces séparés — **ne jamais activer `shareProcessNamespace`** |
| Le pod ne peut pas router vers le cluster/LAN | pas de `net.ipv4.ip_forward` dans le netns |

> ⚠️ Cilium n'applique **pas** ses NetworkPolicies au trafic qui arrive déchiffré sur
> `wg1` : l'interface est hors de sa datapath eBPF. Les règles `iptables` du sidecar
> `wg-tunnel` sont la seule barrière de ce côté — ne pas les retirer en croyant que
> `media-share/networkpolicy.yaml` prend le relais.

> ⚠️ **Le sous-réseau du tunnel (`10.20.0.0/24`) est dans `10.0.0.0/8`**, que gluetun
> détourne du VPN via `FIREWALL_OUTBOUND_SUBNETS` pour laisser passer le trafic
> cluster. Deux conséquences que le sidecar doit compenser explicitement, sans quoi
> le handshake s'établit mais **aucune donnée ne circule** :
>
> - gluetun pose en priorité 99 une règle `to 10.0.0.0/8 lookup 199`, et la table 199
>   renvoie tout vers `eth0`. La route `10.20.0.2 dev wg1` vit dans `main`
>   (priorité 32766) et n'est donc jamais consultée → une `ip rule` dédiée au seul
>   `/32` du pair, en priorité 10, la restaure.
> - la chaîne `OUTPUT` de gluetun est en politique `DROP` et n'autorise que `lo`,
>   `eth0` et son propre `tun0`. Le paquet interne traverse `OUTPUT` avec `out=wg1`
>   **avant** encapsulation → il faut un `ACCEPT` explicite sur `wg1`.
>
> Diagnostic : `ip route get 10.20.0.2` doit répondre `dev wg1`, pas `dev eth0`.

**Ce que ça ne cache pas** : le pair lit les octets des fichiers (c'est le but — il peut
tout copier), et il voit noms, arborescence et tailles. Mullvad, lui, voit les volumes
et les horaires : le chiffrement protège le *quoi*, pas le *combien* ni le *quand*.

#### Mise en service

1. Créer le répertoire des bibliothèques distantes **avec le bon propriétaire**, avant
   le premier sync. Un `hostPath` en `DirectoryOrCreate` serait créé par le kubelet en
   `root:root 0755`, et le CronJob (qui tourne en `1000:984`) ne pourrait pas y écrire :

```bash
sudo install -d -o 1000 -g 984 -m 2775 /mnt/hdd/media/remote
```

2. Générer la paire de clés du pod, ajouter l'item `media-share` au vault `k8s-home` :

```bash
wg genkey | tee /tmp/wg-priv | wg pubkey   # la privée dans wg-private-key, la publique pour le pair
```

   Champs de l'item : `wg-private-key`, `wg-peer-public-key`, `wg-peer-endpoint`
   (`host:port`), et optionnellement `wg-preshared-key` (`wg genpsk`) — une couche
   symétrique en plus, qui doit être **identique des deux côtés** (une PSK d'un seul
   côté fait échouer le handshake sans message explicite) et **propre à ce lien** :
   ne jamais recycler celle d'un autre tunnel. La clé privée se génère hors du
   cluster et n'y entre que par 1Password ; le pod ne fait que la lire. La clé publique et l'endpoint du pair vivent dans 1Password et pas
   dans le manifest : `.github/scripts/mirror-sanitize.py` ne sanitise que le domaine
   et le peer VPS LiveKit, tout autre identifiant réseau partirait tel quel sur le
   miroir public.

3. Côté pair, le peer correspondant. **Laisser `Endpoint` vide** : c'est harkesh qui
   compose (via Mullvad), WireGuard apprend l'adresse au premier handshake et suit les
   rotations d'IP de sortie.

   Le mécanisme de retour est la partie contre-intuitive : le pair n'« entre » jamais,
   il **répond dans un tunnel que harkesh tient ouvert**. Une fois le handshake fait,
   WireGuard est symétrique — le pair émet vers l'ip:port source d'où le handshake est
   arrivé, c'est-à-dire la sortie Mullvad. Ce n'est pas une connexion entrante non
   sollicitée mais du retour sur un flux établi, d'où le fait que ça marche alors que
   Mullvad ne propose plus de port forwarding. C'est `persistent-keepalive 25` côté
   harkesh qui maintient le mapping NAT de la sortie Mullvad (timeout UDP usuel
   30–120 s). Corollaire : si le pod `media-share` est arrêté, le pair n'a aucun moyen
   de rétablir la liaison lui-même — il n'a pas d'endpoint à composer, il attend que
   harkesh re-compose.

```ini
[Interface]
PrivateKey = <clé privée du pair>
Address    = 10.20.0.2/32
ListenPort = 51820
MTU        = 1200

[Peer]
PublicKey  = <clé publique du pod, étape 1>
AllowedIPs = 10.20.0.1/32
```

   Le pair doit ouvrir **UDP/51820** en entrée. Rien à ouvrir côté harkesh.

4. Ajouter dans Jellyfin une bibliothèque pointant sur `/remote/peer1`. Sur cette
   bibliothèque **uniquement**, désactiver : trickplay, extraction des chapitres,
   analyse au démarrage, surveillance temps réel. Sinon Jellyfin rapatrie l'intégralité
   des fichiers du pair pour générer les vignettes.

   Le nom du répertoire vient de `PEER_NAME` dans `media-share/strm-sync.yaml`.

#### Vérification

```bash
# Interface montée : attendu "state UNKNOWN" (normal pour WireGuard) et mtu 1200.
# Un "state DOWN" ou un mtu 1420 signale que la configuration s'est interrompue.
kubectl exec -n media deploy/media-share -c wg-tunnel -- ip addr show wg1

# Handshake établi (ligne "latest handshake" présente)
kubectl exec -n media deploy/media-share -c wg-tunnel -- wg show wg1

# Le filtre du tunnel est bien posé : ACCEPT tcp/8080 sur wg1 en TÊTE de chaîne,
# DROP sur wg1 en fin. -v est indispensable, sans lui la colonne "in" est masquée
# et les règles de gluetun (bornées à lo/eth0) sont indiscernables des nôtres.
kubectl exec -n media deploy/media-share -c wg-tunnel -- iptables -L INPUT -n -v --line-numbers

# Export local : valide le bind sur l'IP du tunnel, le montage /media et le
# listing JSON, sans dépendre du pair. C'est le test le plus utile au bring-up.
kubectl exec -n media deploy/media-share -c proxy -- wget -qO- http://10.20.0.1:8080/

# Le pair est joignable et sert bien du JSON (nécessite le tunnel up)
kubectl exec -n media deploy/media-share -c proxy -- wget -qO- http://10.20.0.2:8080/

# Lecture seule, côté déclaratif : le montage de sws doit porter readOnly:true
kubectl -n media get deploy media-share \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="sws")].volumeMounts}'

# Lecture seule, côté fonctionnel : c'est la seule surface que le pair peut
# atteindre, et elle n'a aucune méthode d'écriture (attendu : 405).
kubectl exec -n media deploy/media-share -c proxy -- \
  wget -S --method=PUT -O /dev/null http://10.20.0.1:8080/ 2>&1 | grep HTTP

# Génération des .strm à la demande
kubectl create job -n media --from=cronjob/media-share-strm-sync strm-sync-manual
kubectl logs -n media job/strm-sync-manual

# Flux refusés
kubectl exec -n kube-system ds/cilium -- hubble observe -n media --verdict DROPPED --follow
```

`sws` tourne sur une image `scratch` : pas de shell, donc `kubectl exec` y est
impossible. `kubectl debug --target=sws` ne comble pas ce manque pour inspecter
les fichiers — un conteneur éphémère partage le namespace de *processus* de la
cible, pas ses volumes, donc `/media` n'y existe pas. D'où les deux vérifications
de lecture seule ci-dessus, déclarative et fonctionnelle, plutôt qu'un `touch`.
