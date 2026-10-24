#!/usr/bin/env bash
# Sauvegarde de harkesh : dumps des bases + snapshot etcd, puis restic (chiffré) vers une
# Hetzner Storage Box (SFTP).
# Installé dans /usr/local/lib/harkesh-backup/ et lancé par les timers systemd du même dossier.
# Procédure d'installation et de restauration : _docs/backup.md.
#
# Usage : harkesh-backup.sh [backup|check]
#   backup (défaut) : dumps -> restic backup -> rotation (forget --prune)
#   check           : restic check avec relecture de 5 % des données
#
# Configuration (hors dépôt) : /etc/harkesh-backup/env, voir env.example.
#
# Métriques : à chaque exécution, /var/lib/node_exporter/textfile/harkesh_backup_<mode>.prom (lu par
# node-exporter, collecteur textfile) : dernière réussite, dernière exécution, statut, durée, et pour
# « backup » le nombre de snapshots et la taille de la dernière sauvegarde. Alertes Grafana « Sauvegarde »
# (monitoring/grafana-alerting.yaml) si la dernière réussite est trop ancienne.
set -Eeuo pipefail

HERE=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source /etc/harkesh-backup/env
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
export KUBECONFIG=/etc/kubernetes/admin.conf
DUMP_DIR=/var/backups/harkesh
MODE=${1:-backup}
UNIT=harkesh-backup; [ "$MODE" = check ] && UNIT=harkesh-backup-check
NC_MAINTENANCE=0
TEXTFILE_DIR=/var/lib/node_exporter/textfile
START=$(date +%s)

# 10 connexions SFTP parallèles (maximum autorisé par une Storage Box, restic en ouvre 5 par défaut)
SFTP_OPTS=(-o sftp.connections=10)
# Paquets de 64 Mio (16 par défaut) : moins d'allers-retours SFTP avec la latence vers la Storage Box
PACK_OPTS=(--pack-size 64)

log() { echo "[harkesh-backup] $*"; }

notify_failure() {
  [ -n "${NTFY_URL:-}" ] || return 0
  curl -fsS -m 10 ${NTFY_TOKEN:+-H "Authorization: Bearer $NTFY_TOKEN"} \
    -H "Title: Sauvegarde harkesh en échec ($MODE)" -H "Priority: high" -H "Tags: warning" \
    -d "$1 — journalctl -u $UNIT -n 50" "$NTFY_URL" >/dev/null || true
}

# Nombre de snapshots et résumé de la dernière sauvegarde (restic >= 0.17 : champ « summary »).
# Jamais bloquant : une métrique manquante ne doit pas faire échouer la sauvegarde.
snapshot_metrics() {
  restic snapshots --json --tag nightly "${SFTP_OPTS[@]}" 2>/dev/null | python3 -c '
import json, sys
snaps = json.load(sys.stdin)
print("# HELP harkesh_backup_snapshots Nombre de snapshots restic (tag nightly) dans le dépôt.")
print("# TYPE harkesh_backup_snapshots gauge")
print(f"harkesh_backup_snapshots {len(snaps)}")
summary = (max(snaps, key=lambda x: x["time"]).get("summary") or {}) if snaps else {}
for key, name, desc in (
    ("data_added", "data_added_bytes", "Données nouvelles de la dernière sauvegarde (après déduplication)."),
    ("total_bytes_processed", "processed_bytes", "Volume parcouru par la dernière sauvegarde."),
    ("total_files_processed", "processed_files", "Fichiers parcourus par la dernière sauvegarde."),
):
    if key in summary:
        print(f"# HELP harkesh_backup_last_{name} {desc}")
        print(f"# TYPE harkesh_backup_last_{name} gauge")
        print(f"harkesh_backup_last_{name} {summary[key]}")
' || true
}

# Métriques de l'exécution (1 = succès, 0 = échec), écrites atomiquement (tmp + mv) et lisibles par
# node-exporter (nobody). En cas d'échec, la date de la dernière réussite est relue dans l'ancien fichier.
write_metrics() {
  local status=$1 now prom last_success
  now=$(date +%s)
  prom="$TEXTFILE_DIR/harkesh_backup_$MODE.prom"
  install -d -m 755 "$TEXTFILE_DIR"
  if [ "$status" = 1 ]; then
    last_success=$now
  else
    last_success=$(awk '/^harkesh_backup_last_success_timestamp_seconds/ {print $2}' "$prom" 2>/dev/null || true)
  fi
  {
    echo "# HELP harkesh_backup_last_success_timestamp_seconds Fin de la dernière exécution réussie (epoch, 0 = jamais)."
    echo "# TYPE harkesh_backup_last_success_timestamp_seconds gauge"
    echo "harkesh_backup_last_success_timestamp_seconds{mode=\"$MODE\"} ${last_success:-0}"
    echo "# HELP harkesh_backup_last_run_timestamp_seconds Fin de la dernière exécution (epoch)."
    echo "# TYPE harkesh_backup_last_run_timestamp_seconds gauge"
    echo "harkesh_backup_last_run_timestamp_seconds{mode=\"$MODE\"} $now"
    echo "# HELP harkesh_backup_last_status Résultat de la dernière exécution (1 = succès, 0 = échec)."
    echo "# TYPE harkesh_backup_last_status gauge"
    echo "harkesh_backup_last_status{mode=\"$MODE\"} $status"
    echo "# HELP harkesh_backup_last_duration_seconds Durée de la dernière exécution."
    echo "# TYPE harkesh_backup_last_duration_seconds gauge"
    echo "harkesh_backup_last_duration_seconds{mode=\"$MODE\"} $((now - START))"
    if [ "$status" = 1 ] && [ "$MODE" = backup ]; then snapshot_metrics; fi
  } > "$prom.tmp"
  chmod 644 "$prom.tmp"
  mv "$prom.tmp" "$prom"
}

nextcloud_maintenance() { # on|off
  kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- \
    su -s /bin/sh www-data -c "php occ maintenance:mode --$1" >/dev/null
}

cleanup() {
  if [ "$NC_MAINTENANCE" = 1 ]; then nextcloud_maintenance off || true; fi
}
trap 'notify_failure "Échec ligne $LINENO"; write_metrics 0 || true' ERR
trap cleanup EXIT

# Dump PostgreSQL en SQL brut (restic compresse et déduplique mieux qu'un -Fc déjà compressé).
# Variables POSTGRES_USER/POSTGRES_DB lues dans l'environnement du conteneur ; socket local = trust.
pg_dump_to() { # namespace cible fichier
  kubectl -n "$1" exec "$2" -- sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner' \
    > "$DUMP_DIR/$3.tmp"
  mv "$DUMP_DIR/$3.tmp" "$DUMP_DIR/$3"
}

dumps() {
  install -d -m 700 "$DUMP_DIR"

  log "dumps PostgreSQL"
  pg_dump_to authentik deploy/postgresql authentik.sql
  pg_dump_to matrix deploy/postgres matrix.sql
  pg_dump_to n8n pod/postgres-0 n8n.sql
  pg_dump_to shlink deploy/postgres shlink.sql

  # Nextcloud : mode maintenance le temps du dump pour que base et fichiers restent cohérents
  log "dump MariaDB (Nextcloud en maintenance)"
  NC_MAINTENANCE=1
  nextcloud_maintenance on
  # Utilisateur applicatif (tous droits sur la base Nextcloud) : MARIADB_ROOT_PASSWORD ne sert qu'à
  # l'initialisation du conteneur et peut ne plus correspondre au mot de passe root réel.
  kubectl -n nextcloud exec deploy/mariadb -- sh -c \
    'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --single-transaction --routines --events --databases "$MARIADB_DATABASE"' \
    > "$DUMP_DIR/nextcloud-mariadb.sql.tmp"
  mv "$DUMP_DIR/nextcloud-mariadb.sql.tmp" "$DUMP_DIR/nextcloud-mariadb.sql"
  nextcloud_maintenance off
  NC_MAINTENANCE=0

  # etcd : snapshot écrit par le pod dans /var/lib/etcd (hostPath), puis déplacé dans DUMP_DIR.
  # Les Secrets y sont chiffrés (secretbox) : la clé /etc/kubernetes/enc est sauvegardée à côté.
  log "snapshot etcd"
  kubectl -n kube-system exec "etcd-$(hostname)" -- etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key snapshot save /var/lib/etcd/harkesh-backup.db >/dev/null
  mv /var/lib/etcd/harkesh-backup.db "$DUMP_DIR/etcd.db"
}

case "$MODE" in
  backup)
    dumps
    log "restic backup"
    restic backup --files-from "$HERE/paths.txt" --exclude-file "$HERE/excludes.txt" \
      --exclude-caches --tag nightly "${SFTP_OPTS[@]}" "${PACK_OPTS[@]}" ${RESTIC_LIMIT_UPLOAD:+--limit-upload "$RESTIC_LIMIT_UPLOAD"}
    log "rotation"
    restic forget --prune --tag nightly "${SFTP_OPTS[@]}" --keep-daily 7 --keep-weekly 4 --keep-monthly 6
    ;;
  check)
    restic check --read-data-subset=5% "${SFTP_OPTS[@]}"
    ;;
  *)
    echo "usage: $0 [backup|check]" >&2
    exit 2
    ;;
esac
write_metrics 1
log "terminé ($MODE)"
