[← Sommaire](README.md)


# Sauvegardes

Sauvegarde quotidienne **chiffrée** (restic : AES-256 + Poly1305, intégrité par SHA-256) vers
une **Hetzner Storage Box BX11** (1 To, SFTP). Scripts et unités systemd dans [`infra/host/backup/`](../infra/host/backup/),
installés sur l'hôte (hors ArgoCD : il faut l'accès à Docker/Pelican, `/etc` et etcd).

| Quoi | Comment |
|---|---|
| Bases (authentik, matrix, n8n, shlink, Nextcloud/MariaDB) | **dumps** SQL cohérents (`pg_dump`, `mariadb-dump` de la base Nextcloud avec l'utilisateur applicatif, Nextcloud en maintenance quelques secondes) — les fichiers bruts des bases sont exclus |
| etcd | `etcdctl snapshot` + `/etc/kubernetes` (PKI, clé de chiffrement des Secrets) |
| Données applicatives | `/srv/appdata`, `/srv/jellyfin/config`, PVC local-path (hors métriques/logs), `/mnt/hdd/data`, `/mnt/hdd/cloud_data` (hors aperçus) |
| Jeux | `/var/lib/pelican` (serveurs Pelican), `/mnt/hdd/rox` (backup Minecraft) |
| Hôte | `/etc/crowdsec`, `/etc/ssh`, DNS, apt, modules, `/etc/pelican` |
| **Exclu** | `/mnt/hdd/media` (films, séries, téléchargements qBittorrent) |

- **Planning** : sauvegarde à 04:00 (`harkesh-backup.timer`), rotation 7 jours / 4 semaines / 6 mois ;
  `restic check` le dimanche à 07:00 avec relecture de 5 % des données (`harkesh-backup-check.timer`).
- **Priorité haute** : la sauvegarde passe avant les serveurs de jeux (`Nice=-5`, I/O best-effort niveau 0),
  10 connexions SFTP parallèles, débit non plafonné (`RESTIC_LIMIT_UPLOAD` vide) — seul le premier envoi
  est long, les suivants sont incrémentaux.
- **Alerte ntfy** (topic `harkesh-backup`) envoyée par le script en cas d'échec.
- **Métriques** : chaque exécution écrit `/var/lib/node_exporter/textfile/harkesh_backup_<mode>.prom`
  (dernière réussite, statut, durée, snapshots, données ajoutées), lu par node-exporter (collecteur
  textfile). Dashboard **Serveur harkesh** → ligne « Sauvegardes ». Alertes Grafana (topic `grafana`) :
  dernière sauvegarde réussie > 26 h, dernière vérification > 8 jours, métriques absentes — couvre aussi
  un timer qui ne tourne plus (aucun échec, donc aucune notification du script).
- **Protection contre un hôte compromis** : les **snapshots automatiques** de la Storage Box ne se
  gèrent que depuis la console Hetzner — un attaquant sur harkesh peut effacer le dépôt restic via SFTP,
  pas les snapshots (10 jours en arrière sur une BX11).

## Mise en place (une fois)

**1. Hetzner Storage Box** (BX11, localisation Allemagne ou Finlande) — dans la console Hetzner :

- activer **SSH support** (et laisser « External reachability » activé) ;
- **Snapshot plan** : snapshot automatique quotidien, 10 conservés ;
- noter l'identifiant `uXXXXXX` (hôte `uXXXXXX.your-storagebox.de`, SSH sur le **port 23**).

**2. Hôte** :

Installer **restic depuis les releases officielles**, pas le paquet Ubuntu : la version d'Ubuntu 24.04
(0.16.4) plafonne à ~5 Mo/s en SFTP vers la Storage Box (latence ~26 ms), contre ~66 Mo/s pour un simple
`sftp put` — les versions récentes gèrent beaucoup mieux la latence.

```bash
V=$(curl -fsSL https://api.github.com/repos/restic/restic/releases/latest | grep -oP '"tag_name": "v\K[^"]+')
cd /tmp && curl -fsSLO "https://github.com/restic/restic/releases/download/v${V}/restic_${V}_linux_amd64.bz2" \
  && curl -fsSLO "https://github.com/restic/restic/releases/download/v${V}/SHA256SUMS"
grep "restic_${V}_linux_amd64.bz2" SHA256SUMS | sha256sum -c -        # doit afficher OK
bunzip2 -f "restic_${V}_linux_amd64.bz2" && install -m 755 "restic_${V}_linux_amd64" /usr/local/bin/restic
restic version
```

```bash
# clé SSH dédiée, sans passphrase (utilisée par le timer)
ssh-keygen -t ed25519 -N '' -C harkesh-backup -f /root/.ssh/storagebox_ed25519
cat >> /root/.ssh/config <<'CONF'
Host storagebox
    HostName uXXXXXX.your-storagebox.de
    User uXXXXXX
    Port 23
    IdentityFile /root/.ssh/storagebox_ed25519
    IdentitiesOnly yes
CONF
ssh-copy-id -s -i /root/.ssh/storagebox_ed25519.pub storagebox   # mot de passe de la Storage Box, une seule fois
ssh storagebox ls                                                # doit répondre sans mot de passe

install -d -m 755 /usr/local/lib/harkesh-backup
cp infra/host/backup/{harkesh-backup.sh,paths.txt,excludes.txt} /usr/local/lib/harkesh-backup/
cp infra/host/backup/*.service infra/host/backup/*.timer /etc/systemd/system/
install -d -m 700 /etc/harkesh-backup
cp infra/host/backup/env.example /etc/harkesh-backup/env && chmod 600 /etc/harkesh-backup/env
# remplir NTFY_TOKEN dans /etc/harkesh-backup/env
openssl rand -base64 32 > /etc/harkesh-backup/restic-password && chmod 600 /etc/harkesh-backup/restic-password
# ⚠️ copier ce mot de passe dans 1Password (vault k8s-home) : sans lui, AUCUNE restauration possible
set -a; . /etc/harkesh-backup/env; set +a
restic init
systemctl daemon-reload && systemctl enable --now harkesh-backup.timer harkesh-backup-check.timer
systemctl start --no-block harkesh-backup.service && journalctl -fu harkesh-backup   # premier envoi (~175 Go, ~30 min)
```

Le token ntfy : `ntfy token add <utilisateur>` dans le pod ntfy, avec un utilisateur autorisé à
publier sur `harkesh-backup` (`ntfy access <utilisateur> harkesh-backup write-only`).

> Premier envoi : le lancer via le service (ou `systemd-run`), **pas** dans un terminal/tmux — un `Ctrl+C`
> ou une session fermée l'interrompt avant l'enregistrement du snapshot (les données déjà envoyées sont
> réutilisées à la relance, mais il faut relancer). Un verrou orphelin se retire avec `restic unlock`.

**Mise à jour des scripts** (après une PR qui touche `infra/host/backup/`) : recopier sur l'hôte

```bash
cp infra/host/backup/{harkesh-backup.sh,paths.txt,excludes.txt} /usr/local/lib/harkesh-backup/
cp infra/host/backup/*.service infra/host/backup/*.timer /etc/systemd/system/ && systemctl daemon-reload
```

## Vérifier

```bash
systemctl list-timers 'harkesh-backup*'
cat /var/lib/node_exporter/textfile/harkesh_backup_backup.prom   # dernière exécution (métriques)
set -a; . /etc/harkesh-backup/env; set +a
restic snapshots                 # une entrée par nuit
restic stats --mode raw-data     # taille réelle sur la Storage Box (après déduplication + compression)
```

## Restaurer

```bash
set -a; . /etc/harkesh-backup/env; set +a
restic snapshots
# fichiers : dans un dossier temporaire, puis recopier ce qui manque
restic restore latest --target /tmp/restore --include /srv/appdata/radarr
# PostgreSQL (ex. shlink) : base vide recréée par le pod, puis
restic dump latest /var/backups/harkesh/shlink.sql | kubectl -n shlink exec -i deploy/postgres -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
# MariaDB (Nextcloud, en maintenance)
restic dump latest /var/backups/harkesh/nextcloud-mariadb.sql | kubectl -n nextcloud exec -i deploy/mariadb -- sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD"'
# etcd : etcdutl snapshot restore /var/backups/harkesh/etcd.db (cluster arrêté) — cf. doc kubeadm
```

**Tester une restauration de temps en temps** (par exemple restaurer `shlink.sql` dans un Postgres
jetable) : une sauvegarde jamais restaurée n'est pas une sauvegarde.
