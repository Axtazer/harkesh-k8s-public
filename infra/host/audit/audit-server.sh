#!/usr/bin/env bash
# Audit en lecture seule de l'hôte harkesh (nœud Kubernetes unique + Docker/Pelican).
# Conçu pour CETTE infrastructure : les valeurs attendues (hôtes des Ingress, namespaces, pods
# privilégiés assumés, chemins hostPath, services de l'hôte) viennent du dépôt — à mettre à jour
# dans le bloc « Référentiel » ci-dessous quand une app est ajoutée ou archivée.
# Procédure et lecture du résultat : _docs/securite.md, « Audit de l'hôte ».
#
# Usage : sudo bash audit-server.sh [--no-external] [--quick] [--days N]
#   --no-external : aucune requête sortante (IP publique, DNS, test Cloudflare Access, test hairpin)
#   --quick       : saute les contrôles lents (SUID, dpkg -V, du, flux Hubble en direct)
#   --days N      : profondeur d'analyse des journaux (défaut 7)
#
# Garanties : n'écrit aucun fichier, ne modifie aucun réglage, n'affiche aucun secret (ni valeur de
# Secret K8s, ni clé privée, ni variable d'environnement de conteneur, ni contenu de .env). Les lignes
# de commande et de cron passent par un filtre qui masque ce qui ressemble à un mot de passe / jeton.
# Sans root, une partie des contrôles est sautée (liste en fin de sortie, section SKIPPED).

set -u
export LC_ALL=C LANG=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

AUDIT_VERSION="1.2"
EXTERNAL=1; QUICK=0; DAYS=7
while [ $# -gt 0 ]; do
  case "$1" in
    --no-external) EXTERNAL=0 ;;
    --quick) QUICK=1 ;;
    --days) shift; DAYS=${1:-7} ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done
case "$DAYS" in ''|*[!0-9]*) DAYS=7 ;; esac

# ───────────────────────────── Référentiel (issu du dépôt) ─────────────────────────────
EXP_HOSTNAME="harkesh"
EXP_NODE_IP="192.168.1.200"            # infra/cilium/values.yaml (k8sServiceHost)
EXP_LAN_IF="eno1"
EXP_SSH_USER="flo"                     # _docs/hote.md (AllowUsers)
EXP_HOLDS="kubeadm kubelet kubectl containerd.io"
# Namespaces applicatifs (deny-all attendu) et namespaces système
APP_NS="alchimie-creatures,authentik,axtazer-me,bots,flo-pro,french-breakfast,livekit,matrix,media,monitoring,n8n,nextcloud,ntfy,pelican,root-panel,shlink,wings"
SYS_NS="cilium-secrets,kube-system,kube-public,kube-node-lease,default,argocd,1password,cloudflare-tunnel-ingress-controller,local-path-storage"
# Hôtes publiés par les Ingress cloudflare-tunnel (*/routes.yaml + argocd/argocd-ingress.yaml)
EXP_HOSTS="go.mydomain2.fr shlink.mydomain2.fr panel.mydomain2.fr node01.mydomain2.fr n8n.mydomain.fr alchimie.mydomain2.fr prowlarr.mydomain2.fr radarr.mydomain2.fr sonarr.mydomain2.fr qbit.mydomain2.fr jellyseerr.mydomain2.fr livekit.mydomain2.fr livekit-jwt.mydomain2.fr matrix.mydomain2.fr maubot.mydomain2.fr croissante.dev stream.mydomain2.fr mydomain2.fr auth.mydomain2.fr ntfy.mydomain2.fr nas.mydomain.fr axtazia.mydomain2.fr grafana.mydomain.fr argocd.mydomain.fr root.mydomain2.fr mydomain.fr dev-pro.mydomain.fr"
# Interfaces d'admin qui doivent répondre 302 → Cloudflare Access (_docs/cloudflare.md)
ACCESS_HOSTS="argocd.mydomain.fr grafana.mydomain.fr n8n.mydomain.fr dev-pro.mydomain.fr root.mydomain2.fr maubot.mydomain2.fr prowlarr.mydomain2.fr radarr.mydomain2.fr sonarr.mydomain2.fr qbit.mydomain2.fr shlink.mydomain2.fr"
# Services systemd de l'hôte
SVC_EXPECTED="kubelet containerd docker systemd-resolved smartmontools unattended-upgrades"
SVC_UNEXPECTED_MED="fail2ban crowdsec cockpit.socket libvirtd cloudflared tailscaled zerotier-one ngrok frpc xrdp x11vnc vncserver teamviewerd anydesk rustdesk nfs-server smbd rpcbind apache2 nginx mysql mariadb postgresql redis-server vsftpd proftpd telnet.socket k3s kube-proxy"
SVC_UNEXPECTED_LOW="avahi-daemon cups cups-browsed snapd ModemManager bluetooth postfix exim4"
# ────────────────────────────────────────────────────────────────────────────────────────

FINDINGS=(); SKIPPED=()
IS_ROOT=0; [ "$(id -u)" = 0 ] && IS_ROOT=1

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n=== %s ===\n' "$1"; }
sub() { printf '\n--- %s\n' "$1"; }
kv() { printf '%-28s %s\n' "$1:" "$2"; }
ind() { sed 's/^/  /'; }
# cap N : garde N lignes et indique combien ont été coupées
cap() { awk -v n="$1" 'NR<=n{print} END{if(NR>n) printf "  … (%d lignes de plus, tronqué)\n", NR-n}'; }
finding() { FINDINGS+=("$1|$2"); printf '  -> [%s] %s\n' "$1" "$2"; }
skip() { SKIPPED+=("$1"); printf '  (sauté : %s)\n' "$1"; }
need_root() { [ "$IS_ROOT" = 1 ] && return 0; skip "$1 — nécessite root"; return 1; }
# Masque tout ce qui ressemble à un secret dans une ligne de commande / de configuration
redact() {
  sed -E \
    -e 's/((pass(word|wd)?|secret|token|api[_-]?key|apikey|auth(orization)?|bearer|credential|private[_-]?key|access[_-]?key)[A-Za-z0-9_-]*["'"'"']?[=: ]+)[^ ]+/\1***/Ig' \
    -e 's#(://[^:/@ ]+:)[^@/ ]+@#\1***@#g'
}
# Les blocs Python renvoient leurs constats sous la forme « @F|NIVEAU|message »
consume() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "@F|"*) line=${line#@F|}; finding "${line%%|*}" "${line#*|}" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}
ip_scope() {
  case "$1" in
    10.*|192.168.*|127.*|169.254.*|::1|fe80:*|fc[0-9a-f][0-9a-f]:*|fd[0-9a-f][0-9a-f]:*) echo prive ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) echo prive ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) echo prive ;;
    *) echo public ;;
  esac
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
HAVE_PY=0; have python3 && HAVE_PY=1

# ════════════════════════════════════════════════════════════════════════════════════════
echo "=== SERVER AUDIT ==="
kv "AUDIT_VERSION" "$AUDIT_VERSION"
kv "DATE" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
kv "HOST" "$(hostname)"
# shellcheck disable=SC1091
kv "OS" "$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-inconnu}")"
kv "KERNEL" "$(uname -r)"
kv "UPTIME" "$(uptime -p 2>/dev/null) — charge $(cut -d' ' -f1-3 /proc/loadavg)"
kv "USER" "$(id -un) (root=$IS_ROOT)"
kv "OPTIONS" "external=$EXTERNAL quick=$QUICK days=$DAYS python3=$HAVE_PY"
if [ "$IS_ROOT" != 1 ]; then
  echo
  echo "ATTENTION : lancé sans root. Sautés : sshd -T, pare-feu, processus des autres comptes, clés SSH,"
  echo "permissions de /etc/kubernetes, CrowdSec, SMART… Relancer avec : sudo bash $0"
  if have sudo && sudo -n true 2>/dev/null; then echo "(sudo sans mot de passe disponible pour ce compte)"; fi
fi
[ "$HAVE_PY" = 1 ] || skip "analyses Kubernetes détaillées (pods, RBAC, NetworkPolicies, audit) — python3 absent"
[ "$(hostname)" = "$EXP_HOSTNAME" ] || finding INFO "Nom d'hôte « $(hostname) » ≠ « $EXP_HOSTNAME » : le référentiel du script vise harkesh"

# ════════════════════════════════════════════════════════════════════════════════════════
section "SYSTEM"
kv "CPU" "$(nproc) cœurs — $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ //')"
free -m | awk '/^Mem:/{printf "%-28s %s Mio total, %s utilisés, %s disponibles\n","RAM:",$2,$3,$7} /^Swap:/{printf "%-28s %s Mio total, %s utilisés\n","SWAP:",$2,$3}'
if [ -n "$(swapon --noheadings --show 2>/dev/null)" ]; then
  finding LOW "Swap actif : kubelet attend normalement un hôte sans swap (vérifier failSwapOn / comportement mémoire des pods)"
fi
kv "NTP synchronisé" "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?')"
kv "Kernel tainted" "$(cat /proc/sys/kernel/tainted 2>/dev/null) (≠0 attendu : module NVIDIA propriétaire)"

sub "Mises à jour"
LATEST_KERNEL=$(find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -1)
kv "Noyau installé le + récent" "${LATEST_KERNEL:-?}"
if [ -n "$LATEST_KERNEL" ] && [ "$LATEST_KERNEL" != "$(uname -r)" ]; then
  finding LOW "Noyau en cours ($(uname -r)) ≠ dernier installé ($LATEST_KERNEL) : reboot en attente"
fi
if [ -f /var/run/reboot-required ]; then
  finding LOW "Reboot requis (/var/run/reboot-required) : $(sort -u /var/run/reboot-required.pkgs 2>/dev/null | paste -sd' ' | cut -c1-200)"
fi
if have apt; then
  UPG=$(apt list --upgradable 2>/dev/null | grep -c '/' || true)
  SEC=$(apt list --upgradable 2>/dev/null | grep -c -- '-security' || true)
  kv "Paquets à mettre à jour" "$UPG (dont sécurité : $SEC)"
  [ "${SEC:-0}" -gt 0 ] && finding MEDIUM "$SEC mise(s) à jour de sécurité apt en attente"
  [ "${UPG:-0}" -gt 40 ] && finding LOW "$UPG paquets à mettre à jour"
  STAMP=/var/lib/apt/periodic/update-success-stamp
  [ -e "$STAMP" ] && kv "Dernier apt update" "$(date -r "$STAMP" '+%Y-%m-%d %H:%M')"
  HOLDS=$(apt-mark showhold 2>/dev/null | paste -sd' ')
  kv "Paquets hold" "${HOLDS:-aucun}"
  for p in $EXP_HOLDS; do in_list "$p" "$HOLDS" || finding LOW "Paquet « $p » non épinglé (apt-mark hold attendu, cf. _docs/hote.md)"; done
  UU=$(systemctl is-enabled unattended-upgrades 2>/dev/null); kv "unattended-upgrades" "${UU:-absent} / $(grep -hs 'Unattended-Upgrade' /etc/apt/apt.conf.d/20auto-upgrades | tr -d '\n')"
  [ -f /etc/apt/apt.conf.d/51unattended-nvidia ] || finding LOW "Blacklist NVIDIA d'unattended-upgrades absente (/etc/apt/apt.conf.d/51unattended-nvidia)"
fi

sub "Services systemd"
FAILED_UNITS=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if [ -n "$FAILED_UNITS" ]; then
  echo "Unités en échec : $(echo "$FAILED_UNITS" | paste -sd' ')"
  for u in $(echo "$FAILED_UNITS" | head -10); do finding MEDIUM "Unité systemd en échec : $u"; done
else
  echo "Unités en échec : aucune"
fi
for s in $SVC_EXPECTED; do
  st=$(systemctl is-active "$s" 2>/dev/null); en=$(systemctl is-enabled "$s" 2>/dev/null)
  printf '  %-30s active=%-9s enabled=%s\n' "$s" "${st:-?}" "${en:-?}"
  if [ "$st" != active ]; then
    case "$s" in
      kubelet|containerd|docker) finding HIGH "Service attendu inactif : $s" ;;
      *) finding MEDIUM "Service attendu inactif : $s" ;;
    esac
  fi
done
printf '  %-30s ssh.service=%s ssh.socket=%s\n' "ssh" "$(systemctl is-active ssh 2>/dev/null)" "$(systemctl is-active ssh.socket 2>/dev/null)"
for t in harkesh-backup.timer harkesh-backup-check.timer; do
  st=$(systemctl is-active "$t" 2>/dev/null)
  printf '  %-30s active=%s\n' "$t" "${st:-?}"
  [ "$st" = active ] || finding HIGH "Timer de sauvegarde inactif : $t"
done
for s in $SVC_UNEXPECTED_MED; do
  if [ "$(systemctl is-active "$s" 2>/dev/null)" = active ]; then
    finding MEDIUM "Service hôte inattendu actif : $s (absent de l'architecture décrite dans le dépôt)"
  fi
done
for s in $SVC_UNEXPECTED_LOW; do
  [ "$(systemctl is-active "$s" 2>/dev/null)" = active ] && finding LOW "Service hôte superflu actif : $s"
done
echo "Services en cours :"
systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{sub(/\.service$/,"",$1); print $1}' | paste -sd' ' | fold -s -w 150 | ind
echo "Sockets systemd à l'écoute :"
systemctl list-units --type=socket --state=listening --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' | fold -s -w 150 | ind

sub "Réglages propres à harkesh (_docs/hote.md)"
RMF=$(systemctl show kubelet -p RequiresMountsFor --value 2>/dev/null)
kv "kubelet RequiresMountsFor" "${RMF:-vide}"
case " $RMF " in *" /mnt/hdd "*) ;; *) finding MEDIUM "kubelet ne dépend pas de /mnt/hdd (drop-in 10-require-mounts.conf absent) : HDD absent au boot = pods sur dossiers vides" ;; esac
kv "Module wireguard" "$(lsmod 2>/dev/null | grep -c '^wireguard') chargé, modules-load.d=$([ -f /etc/modules-load.d/wireguard.conf ] && echo oui || echo non)"
lsmod 2>/dev/null | grep -q '^wireguard' || finding LOW "Module wireguard non chargé (gluetun / LiveKit en dépendent)"
kv "resolv.conf kubelet" "$(grep -c '^nameserver' /etc/kubernetes/resolv.conf 2>/dev/null || echo absent) nameserver(s)"
if grep -rqs '10\.96\.0\.10' /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d 2>/dev/null; then
  finding HIGH "systemd-resolved référence CoreDNS (10.96.0.10) : configuration à l'origine de l'incident du 2026-10-11"
fi
kv "resolved" "$(grep -hsE '^(DNS|DNSOverTLS|DNSSEC|FallbackDNS)=' /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d/*.conf 2>/dev/null | paste -sd' ')"
if have nvidia-smi; then
  kv "GPU" "$(timeout 15 nvidia-smi --query-gpu=name,driver_version,temperature.gpu,utilization.gpu --format=csv,noheader 2>&1 | head -1)"
  kv "GSP désactivé" "$([ -f /etc/modprobe.d/nvidia-gsp.conf ] && echo oui || echo 'non (fichier absent)')"
fi
kv "AppArmor" "$(aa-status 2>/dev/null | sed -n '2p;4p' | paste -sd',' | sed 's/^ *//' || echo '?')"

sub "sysctl"
for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv6.conf.all.disable_ipv6 "net.ipv6.conf.$EXP_LAN_IF.accept_ra" \
         net.ipv4.conf.all.rp_filter net.ipv4.tcp_syncookies kernel.unprivileged_bpf_disabled kernel.kptr_restrict \
         kernel.dmesg_restrict kernel.yama.ptrace_scope kernel.unprivileged_userns_clone fs.protected_symlinks fs.suid_dumpable; do
  printf '  %-44s %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo n/a)"
done
[ "$(sysctl -n kernel.unprivileged_bpf_disabled 2>/dev/null)" = 0 ] && finding LOW "kernel.unprivileged_bpf_disabled=0 : BPF utilisable sans privilège sur un hôte qui exécute des conteneurs de jeux"
[ "$(sysctl -n fs.suid_dumpable 2>/dev/null)" = 1 ] && finding LOW "fs.suid_dumpable=1"

# ════════════════════════════════════════════════════════════════════════════════════════
section "USERS"
echo "Comptes avec shell de connexion (nom:uid:gid:home:shell) :"
LOGIN_USERS=$(awk -F: '$7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1":"$3":"$4":"$6":"$7}' /etc/passwd)
echo "$LOGIN_USERS" | ind
while IFS=: read -r u uid _ _ _; do
  [ -z "$u" ] && continue
  if [ "$uid" = 0 ] && [ "$u" != root ]; then finding CRITICAL "Compte UID 0 autre que root : $u"; fi
  if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65000 ] && [ "$u" != "$EXP_SSH_USER" ]; then
    finding MEDIUM "Compte interactif inattendu : $u (uid $uid) — seul « $EXP_SSH_USER » est documenté"
  fi
  if [ "$uid" -gt 0 ] && [ "$uid" -lt 1000 ]; then
    finding LOW "Compte système avec shell de connexion : $u (uid $uid)"
  fi
done <<< "$LOGIN_USERS"
awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd | while read -r u; do echo "  UID 0 : $u"; done
kv "Dernière modif passwd/shadow" "$(date -r /etc/passwd '+%Y-%m-%d') / $(date -r /etc/shadow '+%Y-%m-%d' 2>/dev/null)"
if need_root "état des mots de passe (passwd -S)"; then
  echo "État des mots de passe (P=défini L=verrouillé NP=VIDE) pour les comptes à shell :"
  while IFS=: read -r u _; do
    [ -z "$u" ] && continue
    st=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
    printf '  %-16s %s\n' "$u" "${st:-?}"
    [ "$st" = NP ] && finding CRITICAL "Compte « $u » sans mot de passe (NP)"
  done <<< "$LOGIN_USERS"
fi
echo "Groupes sensibles :"
for g in sudo adm docker lxd libvirt media root wheel; do
  m=$(getent group "$g" 2>/dev/null | awk -F: '{print $3" : "$4}')
  [ -n "$m" ] && printf '  %-10s gid %s\n' "$g" "$m"
done
DOCKER_MEMBERS=$(getent group docker 2>/dev/null | cut -d: -f4)
[ -n "$DOCKER_MEMBERS" ] && finding INFO "Membres du groupe docker (équivalent root via le socket) : $DOCKER_MEMBERS"
SUDO_MEMBERS=$(getent group sudo 2>/dev/null | cut -d: -f4)
for u in ${SUDO_MEMBERS//,/ }; do [ "$u" = "$EXP_SSH_USER" ] || finding MEDIUM "Membre inattendu du groupe sudo : $u"; done

sub "sudo"
if need_root "lecture de sudoers"; then
  echo "Fichiers : $(find /etc/sudoers.d -type f -printf '%f(%m) ' 2>/dev/null)"
  NOPW=$(grep -rHsE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null)
  if [ -n "$NOPW" ]; then
    echo "$NOPW" | cap 10 | ind
    finding LOW "Règles sudo NOPASSWD présentes ($(echo "$NOPW" | wc -l)) : vérifier que la commande autorisée n'est pas modifiable par le compte concerné"
  else
    echo "  aucune règle NOPASSWD"
  fi
  find /etc/sudoers.d -type f ! -perm 0440 2>/dev/null | while read -r f; do echo "  permissions ≠ 0440 : $f"; done
fi

sub "Dernières connexions"
last -n 12 -a 2>/dev/null | grep -v '^$' | grep -v 'wtmp begins' | ind
if [ "$IS_ROOT" = 1 ]; then kv "Échecs enregistrés (btmp)" "$(lastb 2>/dev/null | grep -vc -e '^$' -e 'btmp begins')"; fi

# ════════════════════════════════════════════════════════════════════════════════════════
section "SSH"
SSH_PORT=22
if need_root "configuration effective de sshd (sshd -T)"; then
  SSHD_T=$(sshd -T 2>/dev/null)
  [ -n "$SSHD_T" ] || skip "sshd -T n'a rien renvoyé (sshd absent ou configuration invalide : lancer « sshd -t »)"
fi
if [ "$IS_ROOT" = 1 ] && [ -n "${SSHD_T:-}" ]; then
  sshd_get() { echo "$SSHD_T" | awk -v k="$1" '$1==k{$1=""; sub(/^ /,""); print; exit}'; }
  for k in port listenaddress permitrootlogin passwordauthentication kbdinteractiveauthentication pubkeyauthentication \
           permitemptypasswords allowusers allowgroups maxauthtries logingracetime x11forwarding allowtcpforwarding \
           allowagentforwarding gatewayports permittunnel authorizedkeysfile authorizedkeyscommand authenticationmethods usepam; do
    v=$(echo "$SSHD_T" | awk -v k="$k" '$1==k{$1=""; sub(/^ /,""); printf "%s ", $0}')
    printf '  %-30s %s\n' "$k" "${v:-(non défini)}"
  done
  SSH_PORT=$(sshd_get port); SSH_PORT=${SSH_PORT:-22}
  [ "$(sshd_get passwordauthentication)" = yes ] && finding HIGH "sshd : PasswordAuthentication yes (clé uniquement attendu)"
  [ "$(sshd_get kbdinteractiveauthentication)" = yes ] && finding MEDIUM "sshd : KbdInteractiveAuthentication yes (mot de passe possible via PAM)"
  [ "$(sshd_get permitemptypasswords)" = yes ] && finding CRITICAL "sshd : PermitEmptyPasswords yes"
  case "$(sshd_get permitrootlogin)" in
    yes) finding HIGH "sshd : PermitRootLogin yes" ;;
    no) ;;
    *) finding LOW "sshd : PermitRootLogin $(sshd_get permitrootlogin) (root déjà exclu par AllowUsers ; « no » serait explicite)" ;;
  esac
  AU=$(sshd_get allowusers)
  if [ -z "$AU" ]; then finding MEDIUM "sshd : AllowUsers absent ($EXP_SSH_USER attendu, 90-hardening.conf)"
  elif [ "$AU" != "$EXP_SSH_USER" ]; then finding MEDIUM "sshd : AllowUsers = « $AU » (attendu : $EXP_SSH_USER)"; fi
  MAT=$(sshd_get maxauthtries); [ "${MAT:-6}" -gt 3 ] && finding LOW "sshd : MaxAuthTries $MAT (3 attendu)"
  [ "$(sshd_get x11forwarding)" = yes ] && finding LOW "sshd : X11Forwarding yes"
  [ "$(sshd_get gatewayports)" != no ] && finding MEDIUM "sshd : GatewayPorts $(sshd_get gatewayports) (tunnels -R exposables sur le réseau)"
  AKC=$(sshd_get authorizedkeyscommand); [ -n "$AKC" ] && [ "$AKC" != none ] && finding MEDIUM "sshd : AuthorizedKeysCommand défini ($AKC) — vecteur de persistance, à vérifier"
  kv "Blocs Match" "$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | grep -cE '^[[:space:]]*Match') (non évalués par sshd -T)"
  kv "sshd_config.d" "$(find /etc/ssh/sshd_config.d -type f -printf '%f ' 2>/dev/null)"
fi
kv "ssh.socket ListenStream" "$(systemctl show ssh.socket -p Listen --value 2>/dev/null | tr '\n' ' ')"

sub "Clés autorisées (empreintes seulement)"
if need_root "authorized_keys de tous les comptes"; then
  while IFS=: read -r u _ _ _ _ home _; do
    for f in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
      [ -s "$f" ] || continue
      n=$(grep -cvE '^[[:space:]]*(#|$)' "$f")
      echo "  $u : $f — $n clé(s), modifié le $(date -r "$f" '+%Y-%m-%d'), mode $(stat -c %a "$f")"
      ssh-keygen -lf "$f" 2>/dev/null | sed 's/^/      /'
      if grep -qE '^[[:space:]]*(command=|environment=|permitopen=|tunnel=)' "$f"; then echo "      (options forcées présentes : command=/environment=/…)"; fi
      if [ "$u" = root ]; then
        finding LOW "root possède $n clé(s) SSH autorisée(s) (inutilisables tant que AllowUsers=$EXP_SSH_USER, mais à justifier)"
      elif [ "$u" != "$EXP_SSH_USER" ]; then
        finding MEDIUM "Clés SSH autorisées pour un compte inattendu : $u ($n clé(s))"
      else
        finding INFO "$n clé(s) SSH autorisée(s) pour $u — vérifier que chaque empreinte listée est connue"
      fi
    done
  done < /etc/passwd
  echo "  Autres fichiers ~/.ssh (nom, mode — jamais le contenu) :"
  for d in /root/.ssh /home/*/.ssh; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -type f ! -name 'authorized_keys*' ! -name 'known_hosts*' -printf '      %p (%m, %TY-%Tm-%Td)\n' 2>/dev/null
    while read -r f; do
      [ -n "$f" ] && finding MEDIUM "Clé privée lisible par d'autres comptes : $f"
    done < <(find "$d" -maxdepth 1 -type f ! -name '*.pub' ! -name 'known_hosts*' ! -name 'config*' ! -name 'authorized_keys*' -perm /077 2>/dev/null)
  done
fi

sub "Journal sshd ($DAYS derniers jours)"
ssh_log() {
  if have journalctl; then journalctl -t sshd -t sshd-session --since "$DAYS days ago" --no-pager -o cat 2>/dev/null
  else cat /var/log/auth.log /var/log/auth.log.1 2>/dev/null | grep 'sshd'; fi
}
SSH_EVENTS=$(ssh_log | awk '
  { ip=""; if (match($0, /[0-9a-fA-F:.]+ port [0-9]+/)) { s=substr($0,RSTART,RLENGTH); split(s,a," "); ip=a[1] } }
  /Accepted / { m=""; u=""; fp="-"; for(i=1;i<=NF;i++){ if($i=="Accepted"){m=$(i+1); u=$(i+3)} if($i ~ /^SHA256:/) fp=$i } print "A", u, m, ip, fp; next }
  /Failed |Invalid user|invalid user|authenticating user|maximum authentication attempts|\[preauth\]|Unable to negotiate|Did not receive identification/ { print "F", (ip==""?"?":ip) }')
N_FAIL=$(echo "$SSH_EVENTS" | grep -c '^F ' || true)
N_ACC=$(echo "$SSH_EVENTS" | grep -c '^A ' || true)
kv "Échecs / sondes pré-auth" "$N_FAIL"
kv "Connexions acceptées" "$N_ACC"
if [ "$N_FAIL" -gt 0 ]; then
  echo "Top sources des échecs :"
  PUB_FAIL=0; PUB_FAIL6=0
  while read -r c ip; do
    sc=$(ip_scope "$ip"); printf '  %6s  %-40s %s\n' "$c" "$ip" "$sc"
  done < <(echo "$SSH_EVENTS" | awk '$1=="F"{print $2}' | sort | uniq -c | sort -rn | head -10)
  while read -r ip; do
    [ "$(ip_scope "$ip")" = public ] || continue
    case "$ip" in *:*) PUB_FAIL6=$((PUB_FAIL6+1)) ;; *.*) PUB_FAIL=$((PUB_FAIL+1)) ;; esac
  done < <(echo "$SSH_EVENTS" | awk '$1=="F"{print $2}' | sort -u)
  kv "IP publiques distinctes" "IPv4=$PUB_FAIL IPv6=$PUB_FAIL6"
  [ "$PUB_FAIL" -gt 0 ] && finding MEDIUM "SSH reçoit des tentatives depuis $PUB_FAIL IPv4 publiques en $DAYS j : le port $SSH_PORT est joignable depuis Internet (redirection sur la box) — nécessaire ? L'architecture n'en a pas besoin"
  [ "$PUB_FAIL6" -gt 0 ] && finding MEDIUM "SSH reçoit des tentatives depuis $PUB_FAIL6 IPv6 publiques : l'hôte est joignable directement en IPv6 (pare-feu IPv6 de la box ouvert ?)"
  [ "$N_FAIL" -gt 2000 ] && finding LOW "Bruteforce/scan SSH soutenu : $N_FAIL échecs en $DAYS j (aucune intrusion déduite de ce seul chiffre)"
fi
if [ "$N_ACC" -gt 0 ]; then
  echo "Connexions acceptées (nb, utilisateur, méthode, source, empreinte de clé) :"
  while read -r c u m ip fp; do
    sc=$(ip_scope "$ip"); printf '  %5s  %-10s %-10s %-38s %-7s %s\n' "$c" "$u" "$m" "$ip" "$sc" "$fp"
    [ "$u" != "$EXP_SSH_USER" ] && finding HIGH "Connexion SSH acceptée pour « $u » depuis $ip (seul $EXP_SSH_USER est attendu) — à vérifier"
    [ "$m" = password ] && finding HIGH "Connexion SSH acceptée par mot de passe ($u depuis $ip)"
    [ "$sc" = public ] && finding MEDIUM "Connexion SSH acceptée depuis une IP publique : $u@$ip ($c fois, clé $fp) — légitime si c'est toi en déplacement, sinon à investiguer"
  done < <(echo "$SSH_EVENTS" | awk '$1=="A"{print $2, $3, $4, $5}' | sort | uniq -c | sort -rn | head -15)
  kv "Empreintes distinctes utilisées" "$(echo "$SSH_EVENTS" | awk '$1=="A"{print $5}' | sort -u | paste -sd' ')"
fi
unset SSH_EVENTS

# ════════════════════════════════════════════════════════════════════════════════════════
section "NETWORK"
echo "Interfaces (hors veth/lxc de Cilium et Docker) :"
ip -br addr 2>/dev/null | grep -vE '^(lxc|veth)' | ind
kv "Interfaces veth/lxc" "$(ip -br link 2>/dev/null | grep -cE '^(lxc|veth)')"
kv "Route par défaut IPv4" "$(ip -4 route show default 2>/dev/null | head -1)"
kv "conntrack" "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo '?') / $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo '?')"
kv "Route par défaut IPv6" "$(ip -6 route show default 2>/dev/null | head -1)"
NODE_IP=$(ip -4 -o addr show dev "$EXP_LAN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
kv "IP du nœud ($EXP_LAN_IF)" "${NODE_IP:-?} (dépôt : $EXP_NODE_IP)"
[ -n "$NODE_IP" ] && [ "$NODE_IP" != "$EXP_NODE_IP" ] && finding MEDIUM "IP du nœud $NODE_IP ≠ $EXP_NODE_IP déclarée dans infra/cilium/values.yaml (k8sServiceHost)"
GLOBAL_V6=$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $2" "$4}' | grep -vE ' f[cd]' | grep -vE '^(lxc|veth|cilium|docker|br-)' )
HAS_GLOBAL_V6=0
if [ -n "$GLOBAL_V6" ]; then HAS_GLOBAL_V6=1; echo "IPv6 globales :"; echo "$GLOBAL_V6" | ind; else echo "IPv6 globale : aucune"; fi
WG_HOST=$(ip -br link show type wireguard 2>/dev/null | awk '{print $1}' | paste -sd' ')
kv "Interfaces WireGuard (hôte)" "${WG_HOST:-aucune}"
[ -n "$WG_HOST" ] && finding MEDIUM "Interface WireGuard sur l'hôte ($WG_HOST) : non prévue (WireGuard vit dans les pods ; sur l'hôte il a déjà cassé cloudflared, incident du 2026-09-01)"

sub "Ports en écoute (netns de l'hôte)"
[ "$IS_ROOT" = 1 ] || echo "  (sans root : noms de processus indisponibles)"
LISTEN=$(ss -H -tulpn 2>/dev/null | awk '
  { proto=$1; loc=$5; n=split(loc,a,":"); port=a[n]; addr=substr(loc,1,length(loc)-length(port)-1);
    proc="-"; p=index($0,"users:((\""); if(p){r=substr($0,p+9); proc=substr(r,1,index(r,"\"")-1)}
    print proto"|"addr"|"port"|"proc }' | sort -u | sort -t'|' -k3,3n)
KNOWN_PROCS='^(sshd|systemd|dockerd|kube-apiserver|etcd|kubelet|kube-controller|kube-scheduler|cilium-agent|cilium-envoy|cilium-operator|cilium-health.*|node_exporter|tetragon|wings|crowdsec|systemd-resolve|containerd|mc2|coolercontrold|chronyd|systemd-timesyn|systemd-network|dhclient|NetworkManager)$'
SENSITIVE_OPEN=""; V6_OPEN=""; LISTEN_PORTS=" "; GAME_TCP=""; GAME_UDP=""
printf '  %-5s %-28s %-6s %-18s %-12s %s\n' PROTO ADRESSE PORT PROCESSUS PORTEE NOTE
while IFS='|' read -r proto addr port proc; do
  [ -z "$proto" ] && continue
  addr=${addr%%\%*}
  case "$addr" in
    127.*|"[::1]"|"[::ffff:127."*) scope=loopback ;;
    0.0.0.0) scope=toutes-v4 ;;
    "*"|"[::]") scope=toutes-v4v6 ;;
    "[fe80"*) scope=lien-local ;;
    *) scope=specifique ;;
  esac
  LISTEN_PORTS="$LISTEN_PORTS$port "
  if [ "$proc" = docker-proxy ]; then
    if [ "$proto" = tcp ]; then GAME_TCP="$GAME_TCP $port"; else GAME_UDP="$GAME_UDP $port"; fi
    continue
  fi
  note=""
  if [ "$proc" = "-" ]; then
    case "$proto/$port" in
      udp/8472) note="VXLAN Cilium (noyau)" ;;
      *) [ "$IS_ROOT" = 1 ] && note="sans processus (noyau : WireGuard, NFS… ?)" ;;
    esac
  elif ! echo "$proc" | grep -qE "$KNOWN_PROCS"; then
    note="INATTENDU"
    if [ "$scope" = loopback ]; then finding LOW "Écoute locale par un processus non référencé : $proc $proto/$port ($addr)"
    else finding MEDIUM "Port en écoute par un processus non référencé : $proc $proto/$port sur $addr"; fi
  fi
  case "$proc" in
    dockerd) if [ "$scope" = loopback ]; then finding HIGH "API Docker en TCP sur loopback ($port) : équivalent root sans authentification pour tout processus local"
             else finding CRITICAL "API Docker exposée en TCP sur $addr:$port"; fi ;;
    etcd) [ "$scope" = toutes-v4 ] || [ "$scope" = toutes-v4v6 ] && finding HIGH "etcd écoute sur toutes les interfaces ($port)" ;;
    crowdsec|containerd) [ "$scope" != loopback ] && finding MEDIUM "$proc écoute hors loopback ($addr:$port)" ;;
    wings) note="Wings : API HTTP en clair (jeton) / SFTP — hostNetwork assumé" ;;
    systemd) [ "$port" != "$SSH_PORT" ] && note="socket systemd (voir la liste des sockets)"
             [ "$port" = 9090 ] && finding MEDIUM "Cockpit (socket systemd 9090) actif : console web d'administration avec connexion par mot de passe, qui contourne la règle SSH « clé uniquement »" ;;
    mc2) note="Eaton IPP (onduleur)" ;;
    coolercontrold) note="CoolerControl (ventilateurs)" ;;
  esac
  [ "$port" = 10255 ] && finding HIGH "Port kubelet en lecture seule (10255) ouvert : expose pods et specs sans authentification"
  if [ "$scope" != loopback ] && [ "$proto" = tcp ]; then
    case "$port" in
      6443|10250|2379|2380|9100|2112|4240|4244|8080|9962|9963|9964|9965) SENSITIVE_OPEN="$SENSITIVE_OPEN $port($proc)" ;;
    esac
  fi
  if [ "$scope" = toutes-v4v6 ]; then V6_OPEN="$V6_OPEN $proto/$port($proc)"; fi
  printf '  %-5s %-28s %-6s %-18s %-12s %s\n' "$proto" "$addr" "$port" "$proc" "$scope" "$note"
done <<< "$LISTEN"
GAME_TCP=$(echo "$GAME_TCP" | tr ' ' '\n' | sort -un | paste -sd' ')
GAME_UDP=$(echo "$GAME_UDP" | tr ' ' '\n' | sort -un | paste -sd' ')
echo "  Ports publiés par Docker (serveurs de jeux Pelican, docker-proxy) :"
echo "    tcp : ${GAME_TCP:-aucun}"
echo "    udp : ${GAME_UDP:-aucun}"
echo "  NB : sous Cilium (kubeProxyReplacement), NodePort / LoadBalancer / hostPort sont servis en eBPF et"
echo "       n'apparaissent PAS ici — voir KUBERNETES > Services et « cilium service list »."

sub "Connexions TCP établies avec des IP publiques (netns de l'hôte uniquement)"
CONNS=$(ss -H -tnp state established 2>/dev/null | awk '
  { l=""; r=""; for(i=1;i<=NF;i++){ if($i ~ /:[0-9]+$/){ if(l=="") l=$i; else if(r=="") r=$i } }
    proc="-"; p=index($0,"users:((\""); if(p){x=substr($0,p+9); proc=substr(x,1,index(x,"\"")-1)}
    n=split(l,a,":"); lp=a[n]; n=split(r,b,":"); rp=b[n]; ra=substr(r,1,length(r)-length(rp)-1); gsub(/\[|\]/,"",ra)
    print lp, ra, rp, proc }')
IN_SUM=""; OUT_SUM=""
while read -r lp ra rp proc; do
  [ -z "$lp" ] && continue
  [ "$(ip_scope "${ra#::ffff:}")" = public ] || continue
  case "$LISTEN_PORTS" in
    *" $lp "*) IN_SUM="$IN_SUM$proc port_local=$lp"$'\n' ;;
    *) OUT_SUM="$OUT_SUM$proc -> port_distant=$rp"$'\n' ;;
  esac
done <<< "$CONNS"
echo "Entrantes (pair public → port en écoute sur l'hôte) :"
if [ -n "$IN_SUM" ]; then
  echo "$IN_SUM" | grep -v '^$' | sort | uniq -c | sort -rn | cap 12 | ind
  while read -r proc lp; do
    lp=${lp#port_local=}
    case "$lp" in
      6443|10250|2379|9100|2112|8080) finding HIGH "Connexion entrante depuis une IP publique sur le port $lp ($proc) : ce port ne devrait jamais être joint depuis Internet — à vérifier" ;;
      "$SSH_PORT") finding INFO "Session SSH en cours depuis une IP publique ($proc)" ;;
    esac
  done < <(echo "$IN_SUM" | grep -v '^$' | sort -u)
else echo "  aucune"; fi
echo "Sortantes (processus de l'hôte → Internet) :"
if [ -n "$OUT_SUM" ]; then
  echo "$OUT_SUM" | grep -v '^$' | sort | uniq -c | sort -rn | cap 20 | ind
  ODD=$(echo "$OUT_SUM" | grep -v '^$' | grep -vE 'port_distant=(443|80|7844|23|22|53|853|123|6443)$' | sort -u | paste -sd';' | cut -c1-300)
  [ -n "$ODD" ] && finding LOW "Connexions sortantes de l'hôte vers des ports inhabituels : $ODD (les pods et conteneurs ont leur propre netns et ne sont pas listés ici)"
else echo "  aucune"; fi
unset CONNS

# ════════════════════════════════════════════════════════════════════════════════════════
section "FIREWALL"
V4_FILTERED=unknown; V6_FILTERED=unknown; UFW_ACTIVE=0
if need_root "pare-feu (ufw / iptables / nftables / ipset)"; then
  if have ufw; then
    UFW_OUT=$(ufw status verbose 2>/dev/null)
    echo "$UFW_OUT" | cap 40 | ind
    echo "$UFW_OUT" | grep -q '^Status: active' && UFW_ACTIVE=1
    kv "ufw IPV6" "$(grep -hs '^IPV6=' /etc/default/ufw)"
  else echo "  ufw absent"; fi
  kv "Backend iptables" "$(iptables -V 2>/dev/null)"
  if have iptables-legacy && [ "$(iptables-legacy -S 2>/dev/null | grep -vc '^-P')" -gt 0 ] && iptables -V 2>/dev/null | grep -q nf_tables; then
    finding LOW "Règles iptables-legacy ET nf_tables présentes en même temps : deux jeux de règles évalués, source classique de trous"
  fi
  IPT=$(iptables -S 2>/dev/null); IP6T=$(ip6tables -S 2>/dev/null)
  echo "Politiques IPv4 : $(echo "$IPT" | grep '^-P' | paste -sd' ')"
  echo "Politiques IPv6 : $(echo "$IP6T" | grep '^-P' | paste -sd' ')"
  kv "Règles IPv4 / IPv6" "$(echo "$IPT" | grep -vc '^-P') / $(echo "$IP6T" | grep -vc '^-P')"
  echo "Chaîne INPUT IPv4 (début) :"; echo "$IPT" | grep '^-A INPUT' | cap 14 | ind
  echo "Chaîne DOCKER-USER :"; echo "$IPT" | grep '^-A DOCKER-USER' | cap 8 | ind
  echo "Chaîne INPUT IPv6 (début) :"; echo "$IP6T" | grep '^-A INPUT' | cap 10 | ind
  if [ "$UFW_ACTIVE" = 1 ] || echo "$IPT" | grep -qE '^-P INPUT (DROP|REJECT)' || echo "$IPT" | grep -qE '^-A INPUT -j (DROP|REJECT)'; then V4_FILTERED=yes; else V4_FILTERED=no; fi
  if echo "$IP6T" | grep -qE '^-P INPUT (DROP|REJECT)' || echo "$IP6T" | grep -qE '^-A INPUT -j (DROP|REJECT)'; then V6_FILTERED=yes
  elif [ "$UFW_ACTIVE" = 1 ] && grep -qs '^IPV6=yes' /etc/default/ufw; then V6_FILTERED=yes
  else V6_FILTERED=no; fi
  if have nft; then
    NFT=$(nft list ruleset 2>/dev/null)
    kv "nftables" "$(echo "$NFT" | grep -c '^table') table(s), $(echo "$NFT" | wc -l) lignes : $(echo "$NFT" | awk '/^table/{printf "%s/%s ", $2, $3}')"
    # Tables nft natives (hors couche de compatibilité iptables-nft) avec un hook input en drop
    if echo "$NFT" | grep -A3 'hook input' | grep -q 'policy drop'; then
      [ "$V4_FILTERED" = no ] && V4_FILTERED=yes
      echo "$NFT" | grep -B8 'hook input' | grep -qE '^table (inet|ip6)' && [ "$V6_FILTERED" = no ] && V6_FILTERED=yes
    fi
    unset NFT
  fi
  kv "Filtrage entrant IPv4 / IPv6" "$V4_FILTERED / $V6_FILTERED"
  sub "CrowdSec dans le pare-feu"
  CS_IN=$(echo "$IPT" | grep -n '^-A INPUT' | grep -c CROWDSEC); CS_DU=$(echo "$IPT" | grep '^-A DOCKER-USER' | grep -c CROWDSEC)
  CS_IN6=$(echo "$IP6T" | grep '^-A INPUT' | grep -c CROWDSEC)
  kv "Saut CROWDSEC dans INPUT" "v4=$CS_IN v6=$CS_IN6 (position v4 : $(echo "$IPT" | grep '^-A INPUT' | grep -n CROWDSEC | cut -d: -f1 | head -1))"
  kv "Saut CROWDSEC dans DOCKER-USER" "$CS_DU"
  if have ipset; then
    echo "ipsets :"; ipset list -t 2>/dev/null | awk '/^Name:/{n=$2} /^Number of entries:/{printf "  %-40s %s entrées\n", n, $4}' | cap 12
  fi
  echo "Compteurs des chaînes CrowdSec (paquets réellement bloqués depuis le dernier (re)chargement) :"
  { iptables -nvL CROWDSEC_CHAIN 2>/dev/null; ip6tables -nvL CROWDSEC_CHAIN 2>/dev/null; } | awk '$3=="DROP"||$3=="REJECT"{printf "  %s paquets, %s octets — %s\n", $1, $2, $NF}' | cap 8
  if echo "$IPT" | grep -q 'CROWDSEC'; then
    [ "$CS_DU" = 0 ] && finding MEDIUM "CrowdSec absent de DOCKER-USER : une IP bannie atteint quand même les serveurs de jeux (Docker contourne INPUT/ufw)"
    [ "$CS_IN6" = 0 ] && [ "$HAS_GLOBAL_V6" = 1 ] && finding LOW "Aucun saut CrowdSec en IPv6 alors que l'hôte a une IPv6 globale"
  fi
  # Conteneurs de jeux Pelican : ni l'hôte (INPUT) ni le LAN (FORWARD) ne doivent leur être ouverts
  if echo "${UFW_OUT:-}" | grep -qE 'ALLOW IN +172\.(1[6-9]|2[0-9]|3[01])\.'; then
    finding HIGH "Règle ufw ouvrant l'hôte aux réseaux Docker (172.16.0.0/12) : les serveurs de jeux joignent kubelet, l'API, Wings, node-exporter… (cf. _docs/hote.md, Pare-feu)"
  fi
  if [ "$(echo "$IPT" | grep -cE '^-A DOCKER-USER .*pelican0.*-j DROP')" -lt 3 ]; then
    finding MEDIUM "DOCKER-USER ne bloque pas pelican0 vers les plages privées : les serveurs de jeux joignent le LAN (box, postes) — règles dans infra/host/ufw/"
  fi
  if [ "$V4_FILTERED" = no ]; then
    finding MEDIUM "Aucun filtrage entrant IPv4 sur l'hôte (ufw inactif, INPUT en ACCEPT ; Cilium hostFirewall désactivé dans le dépôt) : tout port en écoute est joignable depuis le LAN ET depuis les conteneurs de jeux Pelican (réseau Docker → hôte). Ports sensibles ouverts :${SENSITIVE_OPEN:- aucun}"
  fi
  unset IPT IP6T
fi
if [ "$HAS_GLOBAL_V6" = 1 ]; then
  case "$V6_FILTERED" in
    no) finding MEDIUM "IPv6 globale sur l'hôte et aucun filtrage entrant IPv6 local : en IPv6 il n'y a pas de NAT, la seule barrière est le pare-feu IPv6 de la box (non vérifiable d'ici). Écoutes concernées :${V6_OPEN:- aucune}. Devient HIGH si un scan IPv6 externe (ou des IPv6 publiques dans les journaux sshd / Hubble / audit) confirme l'accès" ;;
    unknown) finding INFO "IPv6 globale présente ; filtrage IPv6 non évalué (root requis). Écoutes v6 :${V6_OPEN:- aucune}" ;;
  esac
fi

# ════════════════════════════════════════════════════════════════════════════════════════
section "CROWDSEC"
if ! have cscli; then
  echo "non installé (retiré le 2026-11-16, cf. _docs/hote.md)"
elif need_root "CrowdSec (cscli)"; then
  kv "Version" "$(cscli version 2>&1 | grep -m1 -i '^version' | awk '{print $2}')"
  kv "LAPI" "$(timeout 15 cscli lapi status 2>&1 | tail -1 | cut -c1-120)"
  kv "CAPI (blocklist communautaire)" "$(timeout 20 cscli capi status 2>&1 | tail -1 | cut -c1-120)"
  kv "Console" "$(timeout 15 cscli console status 2>&1 | grep -ciE 'true|✅') option(s) activée(s)"
  echo "Bouncers :"; timeout 15 cscli bouncers list 2>/dev/null | cap 8 | ind
  echo "Collections :"; timeout 15 cscli collections list -o raw 2>/dev/null | awk -F, 'NR>1{printf "%s ", $1}' | fold -s -w 150 | ind; echo
  echo "Sources de logs (acquisition) :"
  grep -hsE '^[[:space:]]*(-[[:space:]]*/|source:|type:|journalctl_filter|filenames?:|-[[:space:]]*"?_SYSTEMD|-[[:space:]]*"?SYSLOG)' /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.d/*.yaml 2>/dev/null | sed 's/^[[:space:]]*//' | paste -sd' ' | fold -s -w 150 | ind
  echo "Décisions actives par origine (CAPI = blocklist, crowdsec = détection locale, cscli = manuel) :"
  timeout 30 cscli decisions list -a -o raw 2>/dev/null | awk -F, 'NR>1{c[$2]++} END{for(k in c) printf "  %-20s %d\n", k, c[k]}'
  echo "Alertes locales sur $DAYS j, par scénario :"
  ALERTS=$(timeout 30 cscli alerts list --since "$((DAYS*24))h" --limit 0 -o raw 2>/dev/null | awk -F, 'NR>1{print $4}')
  if [ -n "$ALERTS" ]; then echo "$ALERTS" | sort | uniq -c | sort -rn | cap 12 | ind; else echo "  aucune"; fi
  kv "Total alertes locales" "$(echo "$ALERTS" | grep -c . || true)"
  echo "Lignes analysées (cscli metrics, acquisition) :"
  { timeout 20 cscli metrics show acquisition 2>/dev/null || timeout 20 cscli metrics 2>/dev/null | sed -n '/[Aa]cquisition/,/^$/p'; } | cap 14 | ind
  ss -H -tlnp 2>/dev/null | grep -q '"crowdsec"' || finding MEDIUM "Aucun socket en écoute pour crowdsec (LAPI 127.0.0.1:8081 attendu)"
fi

# ════════════════════════════════════════════════════════════════════════════════════════
section "DOCKER"
if ! have docker; then
  echo "docker absent"; finding INFO "Docker absent alors que Wings (Pelican) en dépend"
elif ! docker info >/dev/null 2>&1; then
  skip "Docker (socket inaccessible — root ou groupe docker)"
else
  kv "Docker" "$(docker info --format '{{.ServerVersion}} — driver {{.Driver}}, cgroup {{.CgroupDriver}}, live-restore={{.LiveRestoreEnabled}}, conteneurs {{.ContainersRunning}}/{{.Containers}}' 2>/dev/null)"
  kv "Options de sécurité" "$(docker info --format '{{.SecurityOptions}}' 2>/dev/null | cut -c1-160)"
  kv "docker.sock" "$(stat -c '%A %U:%G' /var/run/docker.sock 2>/dev/null)"
  if [ -f /etc/docker/daemon.json ]; then echo "daemon.json :"; redact < /etc/docker/daemon.json | cap 25 | ind; fi
  grep -qs '"hosts"' /etc/docker/daemon.json && finding MEDIUM "daemon.json définit « hosts » : vérifier qu'aucun socket TCP n'est exposé"
  echo "Réseaux : $(docker network ls --format '{{.Name}}({{.Driver}})' 2>/dev/null | paste -sd' ')"
  echo "Conteneurs (nom | image | état | ports) :"
  docker ps -a --format '{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}' 2>/dev/null | cut -c1-230 | cap 40 | ind
  echo "Analyse des conteneurs en cours (aucune variable d'environnement lue) :"
  DOCKER_IDS=$(docker ps -q 2>/dev/null)
  if [ -n "$DOCKER_IDS" ]; then
    # shellcheck disable=SC2086
    while IFS='|' read -r name image priv net pid caps user ro secopt mounts; do
      [ -z "$name" ] && continue
      flags=""
      [ "$priv" = true ] && { flags="$flags privileged"; finding HIGH "Conteneur Docker privilégié : $name ($image) — un serveur de jeu ne doit jamais l'être"; }
      [ "$net" = host ] && { flags="$flags net=host"; finding MEDIUM "Conteneur Docker en réseau hôte : $name ($image)"; }
      [ "$pid" = host ] && { flags="$flags pid=host"; finding HIGH "Conteneur Docker avec pid=host : $name"; }
      case "$mounts" in *docker.sock*|*containerd.sock*) flags="$flags SOCKET-RUNTIME"; finding HIGH "Conteneur Docker avec le socket du runtime monté : $name ($image) = contrôle total de l'hôte" ;; esac
      [ "$caps" != "[]" ] && [ -n "$caps" ] && { flags="$flags cap_add=$caps"; finding MEDIUM "Conteneur Docker avec capabilities ajoutées $caps : $name"; }
      odd=$(echo "$mounts" | tr ' ' '\n' | grep -v '^$' | grep -vE '^(/var/lib/pelican/|/tmp/pelican/|/etc/pelican/|/var/lib/docker/volumes/|/etc/(localtime|timezone|machine-id|passwd|group):)' | paste -sd' ' | cut -c1-200)
      [ -n "$odd" ] && { flags="$flags mounts-hors-pelican=[$odd]"; finding MEDIUM "Conteneur Docker $name monte des chemins hors de Pelican : $odd"; }
      case "$secopt" in *no-new-privileges*) ;; *) flags="$flags sans-no-new-privileges" ;; esac
      printf '  %-38s user=%-10s ro_rootfs=%-5s%s\n' "$(echo "$name" | cut -c1-38)" "${user:-root?}" "$ro" "${flags:- ok}"
    done < <(docker inspect --format '{{.Name}}|{{.Config.Image}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.PidMode}}|{{.HostConfig.CapAdd}}|{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.SecurityOpt}}|{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' $DOCKER_IDS 2>/dev/null | cap 40)
  else echo "  aucun conteneur en cours"; fi
  ADMINISH=$(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' | grep -oE '(0\.0\.0\.0|\[::\]|::):(22|80|443|2375|2376|3306|5432|6379|8080|9000|27017)->' | sort -u | paste -sd' ')
  [ -n "$ADMINISH" ] && finding MEDIUM "Docker publie des ports d'administration / de base de données sur toutes les interfaces : $ADMINISH"
  finding INFO "Ports de jeux publiés par Docker — tcp: ${GAME_TCP:-aucun} / udp: ${GAME_UDP:-aucun}. À comparer aux redirections de la box : tout port publié ET redirigé est exposé hors Cloudflare (voulu pour les jeux uniquement)"
fi

# ════════════════════════════════════════════════════════════════════════════════════════
section "KUBERNETES"
K8S_OK=0
if [ "$IS_ROOT" = 1 ] && [ -r /etc/kubernetes/admin.conf ]; then export KUBECONFIG=/etc/kubernetes/admin.conf; fi
k() { timeout 45 kubectl --request-timeout=20s "$@" 2>/dev/null; }
if ! have kubectl; then
  skip "Kubernetes (kubectl absent)"
elif ! k get --raw /readyz >/dev/null; then
  skip "Kubernetes (API injoignable ou kubeconfig absent pour $(id -un))"
  finding INFO "API Kubernetes non interrogeable par ce compte : relancer en root, ou l'API server est arrêté"
else
  K8S_OK=1
fi

if [ "$IS_ROOT" = 1 ] && [ -d /etc/kubernetes ]; then
  sub "Plan de contrôle (fichiers de l'hôte)"
  kv "Versions" "kubelet $(kubelet --version 2>/dev/null | awk '{print $2}'), kubeadm $(kubeadm version -o short 2>/dev/null), containerd $(containerd --version 2>/dev/null | awk '{print $3}')"
  # kubelet ignore les fichiers cachés (.kubelet-keep) : ils ne lancent aucun pod
  MANIFESTS=$(find /etc/kubernetes/manifests -maxdepth 1 -type f ! -name '.*' -printf '%f ' 2>/dev/null)
  kv "Static pods" "$MANIFESTS"
  for f in $MANIFESTS; do
    case "$f" in kube-apiserver.yaml|kube-controller-manager.yaml|kube-scheduler.yaml|etcd.yaml) ;;
      *) finding HIGH "Manifest de static pod inattendu : /etc/kubernetes/manifests/$f (lancé par kubelet hors API, hors ArgoCD : vecteur de persistance) — à vérifier" ;; esac
  done
  API=/etc/kubernetes/manifests/kube-apiserver.yaml
  if [ -r "$API" ]; then
    echo "Flags kube-apiserver :"
    grep -oE -- '--(advertise-address|bind-address|anonymous-auth|authorization-mode|enable-admission-plugins|encryption-provider-config|audit-log-path|audit-policy-file|audit-log-max[a-z]+|insecure-port|secure-port|token-auth-file|basic-auth-file|profiling|service-node-port-range|kubelet-certificate-authority)=[^ ]*' "$API" | ind
    grep -q -- '--authorization-mode=.*RBAC' "$API" || finding CRITICAL "kube-apiserver sans RBAC dans --authorization-mode"
    grep -q -- '--authorization-mode=.*AlwaysAllow' "$API" && finding CRITICAL "kube-apiserver : AlwaysAllow dans --authorization-mode"
    grep -q -- '--encryption-provider-config=' "$API" || finding MEDIUM "kube-apiserver sans --encryption-provider-config (chiffrement etcd documenté dans _docs/hote.md)"
    grep -q -- '--audit-log-path=' "$API" || finding LOW "kube-apiserver sans audit (--audit-log-path absent)"
    grep -qE -- '--(token-auth-file|basic-auth-file)=' "$API" && finding HIGH "kube-apiserver avec fichier d'authentification statique"
    grep -q -- '--anonymous-auth=false' "$API" || echo "  (anonymous-auth par défaut : l'accès anonyme dépend alors du RBAC — voir RBAC)"
  fi
  if [ -r /etc/kubernetes/manifests/etcd.yaml ]; then
    echo "etcd : $(grep -oE -- '--(listen-client-urls|listen-peer-urls|listen-metrics-urls|client-cert-auth|peer-client-cert-auth)=[^ ]*' /etc/kubernetes/manifests/etcd.yaml | paste -sd' ')"
    grep -q -- '--client-cert-auth=true' /etc/kubernetes/manifests/etcd.yaml || finding HIGH "etcd sans --client-cert-auth=true"
  fi
  KCFG=/var/lib/kubelet/config.yaml
  if [ -r "$KCFG" ]; then
    echo "kubelet : $(grep -E '^(readOnlyPort|resolvConf|staticPodPath|staticPodURL|rotateCertificates|serverTLSBootstrap|protectKernelDefaults|failSwapOn|address):' "$KCFG" | paste -sd' ')"
    echo "kubelet authn/authz : $(awk '/^authentication:/{f=1} /^authorization:/{f=1} f&&/^[a-z]/&&!/^auth/{f=0} f' "$KCFG" | tr -s ' \n' ' ')"
    awk '/anonymous:/{getline; if ($0 ~ /enabled: true/) exit 3}' "$KCFG"; [ $? = 3 ] && finding CRITICAL "kubelet : authentification anonyme activée (port 10250 = exécution de commandes dans tous les pods)"
    grep -qE '^[[:space:]]*mode: AlwaysAllow' "$KCFG" && finding CRITICAL "kubelet : authorization mode AlwaysAllow"
    grep -qE '^readOnlyPort: [1-9]' "$KCFG" && finding HIGH "kubelet : readOnlyPort activé"
    grep -q '^staticPodURL' "$KCFG" && finding HIGH "kubelet : staticPodURL défini (pods chargés depuis une URL)"
    grep -q 'resolvConf: /etc/kubernetes/resolv.conf' "$KCFG" || finding LOW "kubelet : resolvConf ≠ /etc/kubernetes/resolv.conf (cf. _docs/hote.md)"
  fi
  echo "Certificats (expiration) :"
  for c in /etc/kubernetes/pki/*.crt /etc/kubernetes/pki/etcd/*.crt /var/lib/kubelet/pki/kubelet-client-current.pem; do
    [ -r "$c" ] || continue
    end=$(openssl x509 -enddate -noout -in "$c" 2>/dev/null | cut -d= -f2)
    printf '  %-58s %s\n' "${c#/etc/kubernetes/}" "$end"
    if ! openssl x509 -checkend $((30*86400)) -noout -in "$c" >/dev/null 2>&1; then
      finding HIGH "Certificat expirant dans moins de 30 jours : $c ($end)"
    elif ! openssl x509 -checkend $((60*86400)) -noout -in "$c" >/dev/null 2>&1; then
      finding MEDIUM "Certificat expirant dans moins de 60 jours : $c ($end)"
    fi
  done
fi

if [ "$K8S_OK" = 1 ]; then
  sub "Nœud"
  k get nodes -o wide --no-headers | ind
  k describe node | awk '/^Conditions:/{f=1} /^Addresses:/{f=0} f' | awk 'NR>2{print $1, $2}' | paste -sd';' | ind
  k describe node | awk '/^Allocated resources:/{f=1} /^Events:/{f=0} f' | grep -E 'cpu|memory|nvidia' | ind
  k top node --no-headers 2>/dev/null | ind
  for cond in MemoryPressure DiskPressure PIDPressure; do
    [ "$(k get nodes -o jsonpath="{.items[0].status.conditions[?(@.type=='$cond')].status}")" = True ] && finding HIGH "Nœud en $cond"
  done
  [ "$(k get nodes -o jsonpath="{.items[0].status.conditions[?(@.type=='Ready')].status}")" = True ] || finding CRITICAL "Nœud NotReady"
  k -n kube-system get ds kube-proxy >/dev/null && finding MEDIUM "DaemonSet kube-proxy présent alors que Cilium le remplace (réinstallé par un kubeadm upgrade sans --skip-phases=addon/kube-proxy ?)"

  sub "Namespaces"
  ALL_NS=$(k get ns --no-headers -o custom-columns=N:.metadata.name | paste -sd' ')
  echo "  $ALL_NS" | fold -s -w 150
  for ns in $ALL_NS; do
    in_list "$ns" "${APP_NS//,/ } ${SYS_NS//,/ }" || finding MEDIUM "Namespace non référencé dans le dépôt : $ns (app archivée dont le namespace est gardé par Prune=false, ou création hors GitOps) — à vérifier"
  done
  NOPSA=$(k get ns -l '!pod-security.kubernetes.io/warn' --no-headers -o custom-columns=N:.metadata.name | paste -sd' ')
  for ns in $NOPSA; do in_list "$ns" "${APP_NS//,/ }" && finding LOW "Namespace applicatif sans label Pod Security (warn/audit restricted) : $ns"; done

  if [ "$HAVE_PY" = 1 ]; then
    sub "Pods : santé et privilèges (hostNetwork, privileged, capabilities, hostPath, hostPort)"
    read -r -d '' PY_PODS <<'PY'
import json, sys
APP = set(sys.argv[1].split(","));
d = json.load(sys.stdin)
def F(l, m): print("@F|%s|%s" % (l, m))
# Privilèges assumés et documentés (_docs/securite.md) : (namespace, fragment du nom du pod)
ALLOW = [("wings", "wings"), ("monitoring", "cadvisor"), ("monitoring", "node-exporter"), ("monitoring", "dcgm"),
         ("monitoring", "vlagent"), ("monitoring", "logs-collector"), ("monitoring", "victoria-logs"),
         ("local-path-storage", "helper-pod")]
ALLOW_CAPS = {"media": {"NET_ADMIN", "NET_RAW"}, "livekit": {"NET_ADMIN"}}
OK_HOSTPATH = ("/srv/appdata", "/srv/jellyfin", "/mnt/hdd", "/dev/net/tun")
DANGER = ("/", "/etc", "/root", "/home", "/proc", "/sys", "/dev", "/run", "/var/run", "/var/lib/kubelet",
          "/var/lib/etcd", "/etc/kubernetes", "/var/lib/docker", "/var/lib/containerd")
BIG_CAPS = {"SYS_ADMIN", "SYS_MODULE", "SYS_PTRACE", "SYS_RAWIO", "DAC_READ_SEARCH", "BPF", "PERFMON", "SYS_BOOT", "ALL"}
by_ns = {}; nodigest = 0; automount = set(); restarts = []; rows = []
for p in d.get("items", []):
    md, sp, st = p["metadata"], p["spec"], p.get("status", {})
    ns, name = md["namespace"], md["name"]
    by_ns[ns] = by_ns.get(ns, 0) + 1
    phase = st.get("phase", "?")
    owner = (md.get("ownerReferences") or [{}])[0].get("kind", "")
    if phase not in ("Running", "Succeeded"):
        F("MEDIUM" if phase == "Pending" else "LOW", "Pod %s/%s en phase %s (%s)" % (ns, name, phase, st.get("reason", "")))
    r = 0
    for cs in (st.get("containerStatuses") or []) + (st.get("initContainerStatuses") or []):
        r += cs.get("restartCount", 0)
        w = (cs.get("state") or {}).get("waiting")
        if w and w.get("reason") not in ("PodInitializing", "ContainerCreating"):
            F("MEDIUM", "Conteneur %s/%s:%s en attente : %s" % (ns, name, cs["name"], w.get("reason")))
        t = (cs.get("lastState") or {}).get("terminated")
        if t and t.get("reason") == "OOMKilled":
            F("LOW", "Conteneur %s/%s:%s tué par OOM au dernier redémarrage (limite mémoire trop basse ?)" % (ns, name, cs["name"]))
    if r >= 10: restarts.append((r, ns + "/" + name))
    if phase == "Succeeded": continue
    flags = []; lvl = []
    sys_ns = ns == "kube-system"
    allowed = sys_ns or any(ns == a and b in name for a, b in ALLOW)
    if sp.get("hostNetwork"): flags.append("hostNetwork"); lvl.append(("HIGH", "hostNetwork"))
    if sp.get("hostPID"): flags.append("hostPID"); lvl.append(("HIGH", "hostPID"))
    if sp.get("hostIPC"): flags.append("hostIPC"); lvl.append(("HIGH", "hostIPC"))
    for c in (sp.get("containers") or []) + (sp.get("initContainers") or []):
        sc = c.get("securityContext") or {}
        if sc.get("privileged"): flags.append("privileged(%s)" % c["name"]); lvl.append(("HIGH", "conteneur privilégié %s" % c["name"]))
        add = set((sc.get("capabilities") or {}).get("add") or [])
        extra = add - ALLOW_CAPS.get(ns, set())
        if add: flags.append("cap+%s" % ",".join(sorted(add)))
        if extra: lvl.append(("HIGH" if extra & BIG_CAPS else "MEDIUM", "capabilities %s (%s)" % (",".join(sorted(extra)), c["name"])))
        for pt in c.get("ports") or []:
            if pt.get("hostPort"): flags.append("hostPort:%s" % pt["hostPort"]); lvl.append(("MEDIUM", "hostPort %s" % pt["hostPort"]))
        img = c.get("image", "")
        if ns in APP and "@sha256:" not in img: nodigest += 1
    for v in sp.get("volumes") or []:
        hp = (v.get("hostPath") or {}).get("path")
        if not hp: continue
        hp = hp.rstrip("/") or "/"
        flags.append("hostPath:" + hp)
        if "docker.sock" in hp or "containerd.sock" in hp or "crio.sock" in hp: lvl.append(("HIGH", "socket du runtime monté (%s)" % hp))
        elif hp in DANGER: lvl.append(("HIGH", "hostPath sensible %s" % hp))
        elif not hp.startswith(OK_HOSTPATH): lvl.append(("MEDIUM", "hostPath hors des chemins de données connus : %s" % hp))
    if ns in APP and sp.get("automountServiceAccountToken") is not False and not (ns == "monitoring"):
        automount.add(ns + "/" + (name.rsplit("-", 2)[0] if owner == "ReplicaSet" else name))
    if flags:
        tag = "systeme" if sys_ns else ("assume" if (allowed or not lvl) else "A-VERIFIER")
        rows.append((0 if tag == "A-VERIFIER" else 1, "%-11s %s/%s : %s" % (tag, ns, name, " ".join(flags))))
        if not allowed:
            for l, m in sorted(set(lvl)):
                F(l, "Pod %s/%s : %s — hors de la liste des privilèges assumés du dépôt" % (ns, name, m))
print("Pods par namespace : " + " ".join("%s=%d" % kv for kv in sorted(by_ns.items())))
print("Pods avec privilèges élevés (systeme = kube-system, assume = documenté, A-VERIFIER = hors référentiel) :")
for _, r in sorted(rows)[:45]: print("  " + r[:260])
if len(rows) > 45: print("  … (%d de plus)" % (len(rows) - 45))
if restarts:
    print("Redémarrages élevés : " + ", ".join("%s(%d)" % (n, r) for r, n in sorted(restarts, reverse=True)[:10]))
    for r, n in sorted(restarts, reverse=True)[:5]:
        if r >= 30: F("LOW", "Pod %s : %d redémarrages" % (n, r))
if automount: F("LOW", "automountServiceAccountToken non désactivé dans des namespaces applicatifs : " + ", ".join(sorted(automount))[:300])
print("Conteneurs applicatifs sans digest épinglé : %d" % nodigest)
PY
    consume < <(k get pods -A -o json | python3 -c "$PY_PODS" "$APP_NS" 2>&1)

    sub "Services exposés hors ClusterIP (NodePort / LoadBalancer / externalIPs — eBPF, invisibles dans ss)"
    read -r -d '' PY_SVC <<'PY'
import json, sys
d = json.load(sys.stdin); n = 0
def F(l, m): print("@F|%s|%s" % (l, m))
for s in d.get("items", []):
    md, sp = s["metadata"], s["spec"]; ns, name, t = md["namespace"], md["name"], sp.get("type")
    ports = ["%s/%s%s" % (p.get("port"), p.get("protocol", "TCP"), (" nodePort=%s" % p["nodePort"]) if p.get("nodePort") else "") for p in sp.get("ports") or []]
    ext = sp.get("externalIPs") or []
    if t in ("NodePort", "LoadBalancer") or ext:
        n += 1
        lb = [i.get("ip") for i in (s.get("status", {}).get("loadBalancer", {}).get("ingress") or [])]
        print("  %s/%s type=%s ports=[%s] lbIP=%s externalIPs=%s" % (ns, name, t, "; ".join(ports), lb, ext))
        if ext: F("HIGH", "Service %s/%s avec externalIPs %s : capte du trafic sur l'IP de l'hôte hors tunnel" % (ns, name, ext))
        elif t == "LoadBalancer" and name == "cilium-gateway-shared-gateway":
            np = [p["nodePort"] for p in sp.get("ports") or [] if p.get("nodePort")]
            F("INFO", "shared-gateway (LoadBalancer %s, sans annonce L2)%s : accès de secours documenté, sans HTTPRoute il ne sert rien" % (lb, (" — ses nodePorts %s répondent quand même sur l'IP du nœud depuis le LAN" % np) if np else ""))
        elif (ns, name) == ("media", "jellyfin-nodeport"): F("INFO", "jellyfin-nodeport (%s) : accès LAN de secours à Jellyfin, exception déclarée dans le dépôt" % "; ".join(ports))
        elif ns == "kube-system": F("LOW", "Service système %s/%s en %s (%s)" % (ns, name, t, "; ".join(ports)))
        else: F("MEDIUM", "Service %s/%s en %s (%s) : joignable sur l'IP du nœud depuis le LAN sans passer par Cloudflare (ni Access, ni WAF) — aucun n'est déclaré dans le dépôt" % (ns, name, t, "; ".join(ports)))
if not n: print("  aucun (conforme au dépôt : tout est en ClusterIP)")
PY
    consume < <(k get svc -A -o json | python3 -c "$PY_SVC" 2>&1)

    sub "Ingress (chemin Cloudflare Tunnel)"
    read -r -d '' PY_ING <<'PY'
import json, sys
exp = set(sys.argv[1].split()); d = json.load(sys.stdin); seen = set()
def F(l, m): print("@F|%s|%s" % (l, m))
for i in d.get("items", []):
    md, sp = i["metadata"], i["spec"]; cls = sp.get("ingressClassName") or md.get("annotations", {}).get("kubernetes.io/ingress.class", "(aucune)")
    for r in sp.get("rules") or []:
        h = r.get("host", "*"); seen.add(h)
        be = ["%s%s->%s:%s" % (h, p.get("path", "/"), p["backend"].get("service", {}).get("name"), (p["backend"].get("service", {}).get("port") or {}).get("number") or (p["backend"].get("service", {}).get("port") or {}).get("name")) for p in (r.get("http") or {}).get("paths") or []]
        mark = "" if h in exp else "  <-- HORS DEPOT"
        print("  %-22s %-18s %s%s" % (md["namespace"], cls, " ".join(be)[:170], mark))
        if h not in exp: F("MEDIUM", "Ingress %s/%s publie « %s », absent des routes du dépôt : exposition créée hors GitOps ou référentiel du script à mettre à jour" % (md["namespace"], md["name"], h))
    if cls != "cloudflare-tunnel": F("HIGH", "Ingress %s/%s en classe « %s » (seule cloudflare-tunnel est prévue)" % (md["namespace"], md["name"], cls))
    if sp.get("tls"): F("INFO", "Ingress %s/%s porte un bloc tls (inutile derrière le tunnel)" % (md["namespace"], md["name"]))
missing = sorted(exp - seen)
if missing: F("LOW", "Hôtes du dépôt sans Ingress dans le cluster : " + " ".join(missing))
print("Hôtes publiés : %d (dépôt : %d)" % (len(seen), len(exp)))
PY
    consume < <(k get ingress -A -o json | python3 -c "$PY_ING" "$EXP_HOSTS" 2>&1)
    kv "IngressClass" "$(k get ingressclass --no-headers -o custom-columns=N:.metadata.name,C:.spec.controller | paste -sd';')"
    [ "$(k get ingressclass --no-headers 2>/dev/null | wc -l)" -gt 1 ] && finding MEDIUM "Plusieurs IngressClass présentes : un second contrôleur d'ingress exposerait des services hors tunnel"

    sub "NetworkPolicies"
    read -r -d '' PY_NP <<'PY'
import json, sys
APP = sys.argv[1].split(","); d = json.load(sys.stdin); ns = {}
def F(l, m): print("@F|%s|%s" % (l, m))
for it in d.get("items", []):
    n = it["metadata"]["namespace"] if "namespace" in it["metadata"] else "(cluster)"
    e = ns.setdefault(n, {"np": 0, "cnp": 0, "di": False, "de": False, "open": []})
    sp = it.get("spec") or {}
    if it["kind"] == "NetworkPolicy":
        e["np"] += 1
        sel = sp.get("podSelector") or {}
        empty = not sel.get("matchLabels") and not sel.get("matchExpressions")
        types = sp.get("policyTypes") or ["Ingress"]
        if empty and "Ingress" in types and not sp.get("ingress"): e["di"] = True
        if empty and "Egress" in types and not sp.get("egress"): e["de"] = True
        for r in sp.get("ingress") or []:
            frm = r.get("from")
            if not frm: e["open"].append("%s (ingress sans « from » = toutes sources)" % it["metadata"]["name"])
            for f in frm or []:
                if (f.get("ipBlock") or {}).get("cidr") in ("0.0.0.0/0", "::/0"): e["open"].append("%s (ingress depuis 0.0.0.0/0)" % it["metadata"]["name"])
    else:
        e["cnp"] += 1
        for r in (sp.get("ingress") or []) + [x for s in (it.get("specs") or []) for x in (s.get("ingress") or [])]:
            ents = r.get("fromEntities") or []
            if "world" in ents or "all" in ents: e["open"].append("%s (CNP fromEntities %s)" % (it["metadata"]["name"], ents))
            if any(c in ("0.0.0.0/0", "::/0") for c in r.get("fromCIDR") or []): e["open"].append("%s (CNP fromCIDR 0.0.0.0/0)" % it["metadata"]["name"])
for n in sorted(set(APP) | set(ns)):
    e = ns.get(n, {"np": 0, "cnp": 0, "di": False, "de": False, "open": []})
    print("  %-38s NetworkPolicy=%-3d Cilium=%-3d deny-all ingress=%-5s egress=%s" % (n, e["np"], e["cnp"], e["di"], e["de"]))
    if n in APP:
        if e["np"] + e["cnp"] == 0: F("HIGH", "Namespace applicatif %s sans aucune NetworkPolicy (deny-all attendu)" % n)
        elif not e["di"]: F("MEDIUM", "Namespace %s : pas de deny-all en entrée détecté" % n)
        elif not e["de"]: F("LOW", "Namespace %s : pas de deny-all en sortie détecté" % n)
    for o in e["open"][:4]: F("LOW", "Namespace %s : règle d'entrée large — %s" % (n, o))
PY
    consume < <(k get networkpolicies.networking.k8s.io,ciliumnetworkpolicies.cilium.io,ciliumclusterwidenetworkpolicies.cilium.io -A -o json | python3 -c "$PY_NP" "$APP_NS" 2>&1)

    sub "RBAC"
    read -r -d '' PY_RBAC <<'PY'
import json, sys
d = json.load(sys.stdin)
def F(l, m): print("@F|%s|%s" % (l, m))
OK_ADMIN = {("Group", "system:masters"), ("Group", "kubeadm:cluster-admins")}
ANON_OK = {"system:public-info-viewer", "kubeadm:bootstrap-signer-clusterinfo", "system:discovery", "system:basic-user", "system:monitoring"}
for b in d.get("items", []):
    kind, md = b["kind"], b["metadata"]; role = b.get("roleRef", {}).get("name"); where = md.get("namespace", "cluster")
    for s in b.get("subjects") or []:
        sk, sn, sns = s.get("kind"), s.get("name"), s.get("namespace", "")
        who = "%s %s%s" % (sk, (sns + "/") if sns else "", sn)
        if role == "cluster-admin" and kind == "ClusterRoleBinding":
            print("  cluster-admin : %-55s (binding %s)" % (who, md["name"]))
            if (sk, sn) in OK_ADMIN: pass
            elif sk == "ServiceAccount" and sns in ("argocd", "kube-system"): F("INFO", "cluster-admin pour %s (attendu pour ArgoCD / composants système)" % who)
            else: F("MEDIUM", "cluster-admin accordé à %s (binding %s) — à justifier" % (who, md["name"]))
        if sn in ("system:anonymous", "system:unauthenticated") and role not in ANON_OK:
            F("HIGH", "Accès anonyme : %s lié à « %s » (%s %s/%s)" % (sn, role, kind, where, md["name"]))
        if sn == "system:authenticated" and role not in ANON_OK and not md["name"].startswith("system:"):
            F("MEDIUM", "Tout compte authentifié est lié à « %s » (%s %s)" % (role, kind, md["name"]))
        if sk == "ServiceAccount" and sn == "default" and role in ("cluster-admin", "admin", "edit"):
            F("MEDIUM", "ServiceAccount default de %s lié à « %s »" % (sns, role))
PY
    consume < <(k get clusterrolebindings,rolebindings -A -o json | python3 -c "$PY_RBAC" 2>&1)
  fi
  kv "Jetons bootstrap kubeadm" "$(k -n kube-system get secrets --field-selector type=bootstrap.kubernetes.io/token --no-headers | wc -l) (0 attendu hors ajout de nœud)"
  [ "$(k -n kube-system get secrets --field-selector type=bootstrap.kubernetes.io/token --no-headers | wc -l)" -gt 0 ] && finding LOW "Jeton(s) bootstrap kubeadm présent(s) : permettent de joindre un nœud au cluster tant qu'ils n'ont pas expiré"
  SA_TOKENS=$(k get secrets -A --field-selector type=kubernetes.io/service-account-token --no-headers -o custom-columns=N:.metadata.namespace,S:.metadata.name | awk '{print $1"/"$2}' | paste -sd' ')
  kv "Jetons de ServiceAccount permanents" "${SA_TOKENS:-aucun}"
  [ -n "$SA_TOKENS" ] && finding LOW "Jetons de ServiceAccount sans expiration (Secrets) : $(echo "$SA_TOKENS" | cut -c1-200)"
  kv "CSR en attente" "$(k get csr --no-headers | grep -c Pending)"
  k -n argocd get secret argocd-initial-admin-secret >/dev/null && finding LOW "Secret argocd-initial-admin-secret encore présent (mot de passe admin initial d'ArgoCD)"

  sub "Chiffrement des Secrets dans etcd (seul le préfixe de l'enveloppe est lu)"
  ETCD_POD=$(k -n kube-system get pods -l component=etcd --no-headers -o custom-columns=N:.metadata.name | head -1)
  if [ "$IS_ROOT" = 1 ] && [ -n "$ETCD_POD" ]; then
    etcdctl_() { k -n kube-system exec "$ETCD_POD" -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key "$@"; }
    ENC=0; PLAIN=0
    for key in $(etcdctl_ get /registry/secrets/ --prefix --keys-only --limit=40 | grep '^/registry' | awk 'NR%8==1' | head -5); do
      pre=$(etcdctl_ get "$key" --print-value-only | head -c 8 | tr -cd 'a-z0-9:')
      case "$pre" in k8s:enc:*) ENC=$((ENC+1)) ;; *) PLAIN=$((PLAIN+1)) ;; esac
    done
    kv "Échantillon de Secrets" "chiffrés=$ENC en clair=$PLAIN"
    [ "$PLAIN" -gt 0 ] && finding HIGH "$PLAIN Secret(s) de l'échantillon stockés en clair dans etcd (réécriture « kubectl get secrets -A -o json | kubectl replace -f - » non faite ou chiffrement inactif)"
  else skip "vérification du chiffrement etcd (root + pod etcd requis)"; fi

  sub "Gateway API / Cilium"
  NROUTES=$(k get httproutes.gateway.networking.k8s.io,grpcroutes.gateway.networking.k8s.io -A --no-headers | wc -l)
  kv "Gateways" "$(k get gateways.gateway.networking.k8s.io -A --no-headers | awk '{print $1"/"$2" addr="$4" programmed="$5}' | paste -sd';')"
  kv "HTTPRoute / GRPCRoute" "$NROUTES (0 attendu)"
  [ "$NROUTES" -gt 0 ] && finding MEDIUM "$NROUTES route(s) Gateway API présentes : chemin d'accès LAN en HTTP clair qui contourne Cloudflare Access (_docs/architecture.md) : $(k get httproutes.gateway.networking.k8s.io -A --no-headers | awk '{print $1"/"$2}' | paste -sd' ')"
  NL2=$(k get ciliuml2announcementpolicies.cilium.io --no-headers | wc -l)
  kv "CiliumL2AnnouncementPolicy" "$NL2 (0 attendu)"
  [ "$NL2" -gt 0 ] && finding MEDIUM "CiliumL2AnnouncementPolicy présente : l'IP du shared-gateway est annoncée en ARP sur le LAN (retirée volontairement dans le dépôt)"
  kv "LB IP pools" "$(k get ciliumloadbalancerippools.cilium.io --no-headers | awk '{print $1}' | paste -sd' ')"
  CIL() { k -n kube-system exec ds/cilium -c cilium-agent -- "$@"; }
  CILBIN=cilium-dbg; CIL $CILBIN version >/dev/null || CILBIN=cilium
  echo "cilium status :"
  CIL $CILBIN status 2>/dev/null | grep -E '^(KubeProxyReplacement|Host firewall|Encryption|Masquerading|Hubble|Cluster health|Cilium:|IPAM|Routing)' | cut -c1-170 | ind
  echo "Frontends servis en eBPF sur l'hôte (NodePort / LoadBalancer / HostPort / ExternalIPs) :"
  CIL $CILBIN service list 2>/dev/null | grep -E 'NodePort|LoadBalancer|HostPort|ExternalIPs' | grep -v '0\.0\.0\.0:' | awk '{print $2, $3}' | sort -u | cap 20 | ind

  sub "Connecteur Cloudflare Tunnel"
  CFNS=cloudflare-tunnel-ingress-controller
  k -n $CFNS get deploy --no-headers | awk '{print "  "$1" ready="$2" à-jour="$3}'
  CFREADY=$(k -n $CFNS get deploy controlled-cloudflared-connector -o jsonpath='{.status.readyReplicas}')
  [ "${CFREADY:-0}" -lt 2 ] && finding HIGH "Connecteur cloudflared : ${CFREADY:-0} réplica(s) prêt(s) sur 2 attendus (seul chemin d'entrée de tous les sites)"
  CFLOG=$(k -n $CFNS logs deploy/controlled-cloudflared-connector --since=24h --tail=4000)
  kv "cloudflared (24 h)" "$(echo "$CFLOG" | grep -c ' ERR ') erreur(s), $(echo "$CFLOG" | grep -c 'Registered tunnel connection') (ré)enregistrement(s), protocole : $(echo "$CFLOG" | grep -oE 'protocol=[a-z0-9]+' | sort | uniq -c | paste -sd' ')"
  echo "$CFLOG" | grep -q 'protocol=quic' && finding LOW "cloudflared utilise QUIC alors que http2 est forcé dans le dépôt (micro-coupures documentées)"
  [ "$(echo "$CFLOG" | grep -c ' ERR ')" -gt 50 ] && finding LOW "cloudflared : $(echo "$CFLOG" | grep -c ' ERR ') erreurs en 24 h (connecteur instable ?)"
  CTLLOG=$(k -n $CFNS logs deploy/cloudflare-tunnel-controller-cloudflare-tunnel-ingress-controller --since=24h --tail=2000)
  kv "controller (24 h)" "$(echo "$CTLLOG" | grep -ciE 'error') ligne(s) d'erreur"
  echo "$CTLLOG" | grep -q 'Authentication error' && finding HIGH "Controller du tunnel : « Authentication error » (token Cloudflare refusé — cf. _docs/cloudflare-tunnel.md, filtrage IP du token)"
  unset CFLOG CTLLOG

  sub "ArgoCD (dérive par rapport au dépôt)"
  ARGO=$(k -n argocd get applications.argoproj.io --no-headers -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status)
  echo "$ARGO" | awk '{printf "%s(%s/%s) ", $1, $2, $3}' | fold -s -w 150 | ind; echo
  while read -r n s h; do
    [ -z "$n" ] && continue
    [ "$s" != Synced ] && finding LOW "Application ArgoCD $n : $s — l'état du cluster diffère du dépôt (changement manuel ou sync en échec)"
    case "$h" in Healthy|"") ;; *) finding MEDIUM "Application ArgoCD $n : santé $h" ;; esac
  done <<< "$ARGO"

  sub "Volumes"
  kv "PV" "$(k get pv --no-headers | awk '{c[$5]++} END{for(s in c) printf "%s=%d ", s, c[s]}')"
  kv "PVC" "$(k get pvc -A --no-headers | awk '{c[$3]++} END{for(s in c) printf "%s=%d ", s, c[s]}')"
  k get pv --no-headers | awk '$5!="Bound"{print $1, $5}' | while read -r n s; do echo "  PV $n : $s"; done
  NB_UNBOUND=$(k get pvc -A --no-headers | awk '$3!="Bound"' | wc -l)
  [ "$NB_UNBOUND" -gt 0 ] && finding MEDIUM "$NB_UNBOUND PVC non lié(s) : $(k get pvc -A --no-headers | awk '$3!="Bound"{print $1"/"$2"("$3")"}' | paste -sd' ')"
  NB_REL=$(k get pv --no-headers | grep -cE 'Released|Failed')
  [ "$NB_REL" -gt 0 ] && finding LOW "$NB_REL PV en Released/Failed (données orphelines à trier)"

  sub "Événements Warning récents (namespace / raison : nombre)"
  k get events -A --field-selector type=Warning --no-headers -o custom-columns=NS:.metadata.namespace,R:.reason | sort | uniq -c | sort -rn | cap 15 | ind
  sub "Pods les plus gourmands (mémoire)"
  k top pods -A --no-headers --sort-by=memory 2>/dev/null | head -10 | ind

  if [ "$HAVE_PY" = 1 ]; then
    sub "Tetragon : exécutions de shells / outils réseau dans les conteneurs (24 h)"
    read -r -d '' PY_TETRA <<'PY'
import json, sys, collections
c = collections.Counter(); n = 0
for line in sys.stdin:
    try: e = json.loads(line)
    except Exception: continue
    p = (e.get("process_exec") or {}).get("process") or {}
    if not p: continue
    n += 1; pod = p.get("pod") or {}
    c[("%s/%s" % (pod.get("namespace", "hote"), (pod.get("container") or {}).get("name", pod.get("name", "?"))), p.get("binary", "?"))] += 1
print("  %d événement(s) process_exec dans l'extrait" % n)
for (w, b), k in c.most_common(15): print("  %6d  %-45s %s" % (k, w, b))
PY
    k -n kube-system logs ds/tetragon -c export-stdout --since=24h --tail=4000 | python3 -c "$PY_TETRA" 2>&1
    echo "  (arguments volontairement non affichés ; détail : Grafana → dashboard Sécurité)"

    sub "Hubble : paquets refusés et trafic extérieur → hôte"
    read -r -d '' PY_HUB <<'PY'
import json, sys, collections, ipaddress
mode = sys.argv[1]; drops = collections.Counter(); wh = collections.Counter(); srcs = collections.defaultdict(set); n = 0
def F(l, m): print("@F|%s|%s" % (l, m))
for line in sys.stdin:
    try: f = json.loads(line)
    except Exception: continue
    f = f.get("flow", f); n += 1
    l4 = f.get("l4") or {}; proto = next(iter(l4), "?"); dport = (l4.get(proto) or {}).get("destination_port", 0)
    s, d = f.get("source") or {}, f.get("destination") or {}
    if mode == "drops":
        who = lambda x: "%s/%s" % (x.get("namespace") or "-", (x.get("pod_name") or ",".join(l for l in x.get("labels", []) if l.startswith("reserved:")) or "?").rsplit("-", 2)[0])
        drops[(who(s), who(d), "%s/%s" % (proto, dport), f.get("drop_reason_desc", "?"))] += 1
    else:
        if proto == "TCP":
            fl = (l4["TCP"].get("flags") or {})
            if not fl.get("SYN") or fl.get("ACK"): continue
        elif proto == "UDP":
            if dport >= 32768 or dport == 8472: continue
        else: continue
        try: ip = ipaddress.ip_address((f.get("IP") or {}).get("source", ""))
        except Exception: continue
        scope = "LAN" if (ip.is_private or ip.is_link_local) else "INTERNET"
        wh[(scope, proto, dport, f.get("verdict", "?"))] += 1; srcs[(scope, proto, dport)].add(str(ip))
if mode == "drops":
    print("  %d paquet(s) refusé(s) dans le tampon — source -> destination port raison : nombre" % n)
    for (a, b, p, r), k in drops.most_common(15): print("  %6d  %s -> %s %s %s" % (k, a, b, p, r))
else:
    print("  %d flux extérieur→hôte observés (tampon Hubble + ~15 s en direct ; fenêtre courte, absence ≠ preuve)" % n)
    for (sc, pr, dp, v), k in sorted(wh.items(), key=lambda x: -x[1])[:25]:
        print("  %6d  %-8s %s/%-6s %-10s %d source(s)" % (k, sc, pr, dp, v, len(srcs[(sc, pr, dp)])))
    SENS = {6443, 10250, 2379, 2380, 9100, 2112, 4240, 4244, 8080, 9962, 9963, 9964, 9965}
    for (sc, pr, dp, v), k in wh.items():
        if sc != "INTERNET" or v != "FORWARDED": continue
        if dp in SENS: F("HIGH", "Trafic Internet reçu sur le port sensible %s/%d de l'hôte (%d paquet(s), %d source(s)) : port redirigé sur la box ou joignable en IPv6 — à fermer" % (pr, dp, k, len(srcs[(sc, pr, dp)])))
        elif dp == 22: F("MEDIUM", "Trafic Internet reçu sur SSH (22) : port joignable hors Cloudflare")
        elif dp == 42022: F("INFO", "Trafic Internet reçu sur le SFTP Wings (42022) : exposition documentée")
        else: F("INFO", "Trafic Internet reçu sur l'hôte %s/%d (%d paquet(s)) : attendu seulement pour les ports de jeux" % (pr, dp, k))
PY
    consume < <(CIL hubble observe --verdict DROPPED --last 3000 -o json 2>/dev/null | python3 -c "$PY_HUB" drops 2>&1)
    if [ "$QUICK" = 0 ]; then
      consume < <(timeout 40 kubectl --request-timeout=30s -n kube-system exec ds/cilium -c cilium-agent -- timeout 15 hubble observe --from-identity 2 --to-identity 1 --last 4000 --follow -o json 2>/dev/null | python3 -c "$PY_HUB" world 2>&1)
    else skip "échantillon Hubble extérieur→hôte (--quick)"; fi
  fi
fi

# ════════════════════════════════════════════════════════════════════════════════════════
section "CLOUDFLARE / EXPOSITION"
cat <<'TXT'
Chemin attendu : Internet → Cloudflare (WAF → Access) → tunnel HAR_K8S → cloudflared (pod) → Service ClusterIP.
Exceptions voulues hors Cloudflare : ports de jeux Docker + SFTP Wings 42022 (redirigés sur la box), média LiveKit via le VPS.
Vérifié localement par ce script : ports en écoute, pare-feu, IPv6, Services NodePort/LoadBalancer, Ingress hors dépôt,
  HTTPRoute, tunnels parallèles sur l'hôte, trafic Internet réellement reçu (journaux sshd, Hubble), réponse Access.
NON vérifiable localement :
  - API Cloudflare : enregistrements DNS « DNS only » pointant vers l'IP du domicile, hostnames ajoutés au tunnel dans le
    dashboard (hors Ingress), autres tunnels/connecteurs du compte, règles WAF, applications et politiques Access, tokens API.
  - Box (Freebox OS) : redirections de ports, DMZ, UPnP, pare-feu IPv6.
  - Vue réelle d'Internet : scan depuis l'extérieur (4G / VPS) de l'IPv4 et de l'IPv6 publiques.
TXT
sub "Tunnels et accès distants parallèles sur l'hôte"
TUN=$(ps -eo pid,user,comm,args 2>/dev/null | grep -iE '(^| |/)(cloudflared|ngrok|frpc|frps|chisel|rathole|bore|tailscaled|zerotier-one|teamviewerd|anydesk|rustdesk|sshuttle|autossh|gost|localtunnel|playit)( |$)|ssh .*-R ' | grep -v grep)
if [ -n "$TUN" ]; then
  while read -r pid user comm args; do
    ctx=hote; grep -qsE 'kubepods|docker' "/proc/$pid/cgroup" && ctx=conteneur
    echo "  [$ctx] pid=$pid user=$user $comm : $(echo "$args" | redact | cut -c1-120)"
    if [ "$ctx" = hote ]; then finding MEDIUM "Outil de tunnel / accès distant lancé directement sur l'hôte : $comm (pid $pid, $user) — hors architecture (cloudflared ne tourne qu'en pod) : chemin d'entrée parallèle à vérifier"; fi
  done <<< "$TUN"
else echo "  aucun (hors pods)"; fi

if [ "$EXTERNAL" = 1 ] && have curl; then
  sub "Vue depuis l'extérieur (requêtes sortantes vers Cloudflare et tes propres domaines)"
  PUB4=$(curl -4 -s -m 6 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
  PUB6=$(curl -6 -s -m 6 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
  kv "IPv4 publique" "${PUB4:-indisponible}"
  kv "IPv6 publique de sortie" "${PUB6:-aucune}"
  echo "Résolution DNS des hôtes publiés (anomalies seulement) :"
  DNS_OK=0
  for h in $EXP_HOSTS; do
    ips=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ')
    if [ -z "$ips" ]; then echo "  $h : pas de réponse"; continue; fi
    bad=0
    for ip in $ips; do
      if [ -n "$PUB4" ] && [ "$ip" = "$PUB4" ]; then bad=1; finding HIGH "DNS : $h résout vers l'IP publique du domicile ($ip) — enregistrement non proxifié, l'origine est exposée hors Cloudflare"
      elif [ "$(ip_scope "$ip")" = prive ]; then bad=1; echo "  $h → $ip (adresse privée : /etc/hosts ou DNS local ?)"
      elif ! echo "$ip" | grep -qE '^(104\.(1[6-9]|2[0-9]|3[01])\.|172\.(6[4-9]|7[01])\.|188\.114\.|162\.15[89]\.|198\.41\.|141\.101\.|108\.162\.|190\.93\.|197\.234\.|103\.(21|22|31)\.|173\.245\.|131\.0\.72\.)'; then
        bad=1; echo "  $h → $ip (hors plages Cloudflare connues)"
        finding LOW "DNS : $h → $ip n'est pas une adresse Cloudflare (enregistrement non proxifié ?)"
      fi
    done
    [ "$bad" = 0 ] && DNS_OK=$((DNS_OK+1))
  done
  echo "  $DNS_OK hôte(s) résolvent vers Cloudflare"
  echo "Cloudflare Access devant les interfaces d'admin (302 → cloudflareaccess.com attendu) :"
  for h in $ACCESS_HOSTS; do
    r=$(curl -s -o /dev/null -m 10 -w '%{http_code} %{redirect_url}' "https://$h/" 2>/dev/null)
    code=${r%% *}; redir=${r#* }
    printf '  %-26s %s %s\n' "$h" "$code" "$(echo "$redir" | cut -d/ -f1-3)"
    case "$code" in
      302|303) echo "$redir" | grep -q 'cloudflareaccess.com' || finding HIGH "$h redirige vers $(echo "$redir" | cut -d/ -f1-3) et non vers Cloudflare Access : application Access manquante ?" ;;
      000) finding INFO "$h : pas de réponse (réseau, DNS ou tunnel)" ;;
      403) finding INFO "$h répond 403 (WAF / blocage géographique) : Access non vérifiable depuis cette IP" ;;
      *) finding HIGH "$h répond $code sans passer par Cloudflare Access (302 attendu) : interface d'admin possiblement ouverte" ;;
    esac
  done
  case "$PUB4" in *[!0-9.]*) PUB4="" ;; esac
  if [ -n "$PUB4" ]; then
    echo "Test indicatif vers ta propre IPv4 publique (hairpin NAT de la box — à confirmer par un scan externe) :"
    for p in 22 80 443 42022 2379 6443 8080 8443 9100 10250; do
      if timeout 3 bash -c "exec 3<>/dev/tcp/$PUB4/$p" 2>/dev/null; then
        echo "  $p/tcp OUVERT"
        case "$p" in
          42022) finding INFO "IP publique:42022 ouvert (SFTP Wings, exposition documentée)" ;;
          22) finding MEDIUM "IP publique:22 répond (hairpin) : SSH probablement redirigé sur la box" ;;
          80|443|8443) finding LOW "IP publique:$p répond (hairpin) : redirection de port, ou interface de la box elle-même — aucun HTTP entrant n'est prévu (tout passe par le tunnel)" ;;
          *) finding HIGH "IP publique:$p répond (hairpin) : port sensible apparemment redirigé depuis Internet — à confirmer de l'extérieur et à fermer" ;;
        esac
      else echo "  $p/tcp fermé/filtré"; fi
    done
  fi
else
  skip "contrôles externes (IP publique, DNS, Access, hairpin) — --no-external ou curl absent"
fi

# ════════════════════════════════════════════════════════════════════════════════════════
section "STORAGE"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | grep -v '^loop' | cap 25 | ind
echo "Espace disque :"
DF=$(df -hPT -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs -x nsfs 2>/dev/null)
echo "$DF" | ind
while read -r _ _ _ _ _ pct mnt; do
  p=${pct%\%}; case "$p" in ''|*[!0-9]*) continue ;; esac
  if [ "$p" -ge 95 ]; then finding HIGH "Disque presque plein : $mnt à $pct"
  elif [ "$p" -ge 85 ]; then finding MEDIUM "Disque chargé : $mnt à $pct (kubelet évince les pods vers 85–90 % sur la partition de containerd)"; fi
done < <(echo "$DF" | tail -n +2)
echo "Inodes :"
DFI=$(df -iP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs -x nsfs 2>/dev/null)
echo "$DFI" | awk 'NR==1 || $5+0 >= 50' | ind
while read -r _ _ _ _ pct mnt; do
  p=${pct%\%}; case "$p" in ''|*[!0-9]*) continue ;; esac
  [ "$p" -ge 85 ] && finding MEDIUM "Inodes : $mnt à $pct"
done < <(echo "$DFI" | tail -n +2)
if mountpoint -q /mnt/hdd 2>/dev/null; then kv "/mnt/hdd" "monté ($(findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/hdd | cut -c1-90))"
else finding HIGH "/mnt/hdd n'est pas monté : Nextcloud, médiathèque, ntfy, shlink et MariaDB en dépendent"; fi
echo "fstab :"; grep -vE '^[[:space:]]*(#|$)' /etc/fstab 2>/dev/null | redact | ind
if have smartctl && need_root "SMART"; then
  echo "SMART :"
  for d in $(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
    H=$(timeout 20 smartctl -H "/dev/$d" 2>/dev/null | grep -iE 'overall-health|SMART Health Status' | awk -F: '{print $2}' | tr -d ' ')
    A=$(timeout 20 smartctl -A "/dev/$d" 2>/dev/null | grep -iE 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Percentage Used|Media and Data Integrity Errors|Power_On_Hours|Power On Hours|^Temperature:|Temperature_Celsius|Available Spare:' | awk '{ if ($1 ~ /^[0-9]+$/) printf "%s=%s ", $2, $10; else { gsub(/ +/," "); printf "%s; ", $0 } }')
    printf '  /dev/%-8s santé=%-8s %s\n' "$d" "${H:-?}" "$(echo "$A" | cut -c1-200)"
    case "$H" in PASSED|OK|"") ;; *) finding CRITICAL "SMART : /dev/$d signale « $H »" ;; esac
    if echo "$A" | grep -qE '(Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable)=[1-9]'; then finding HIGH "SMART : /dev/$d a des secteurs réalloués / en attente ($(echo "$A" | grep -oE '(Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable)=[0-9]+' | paste -sd' '))"; fi
  done
fi
if grep -qs '^md' /proc/mdstat; then
  echo "RAID :"; grep -A2 '^md' /proc/mdstat | ind
  grep -qE '\[U*_[U_]*\]' /proc/mdstat && finding HIGH "RAID md dégradé"
fi

sub "Sauvegardes (restic → Storage Box)"
systemctl list-timers 'harkesh-*' --no-legend 2>/dev/null | cut -c1-150 | ind
for u in harkesh-backup harkesh-backup-check; do
  kv "$u.service" "$(systemctl show "$u.service" -p Result -p ExecMainStatus -p ExecMainExitTimestamp 2>/dev/null | paste -sd' ')"
done
NOW=$(date +%s)
for m in backup check; do
  f=/var/lib/node_exporter/textfile/harkesh_backup_$m.prom
  if [ -r "$f" ]; then
    ls_=$(awk '/^harkesh_backup_last_success_timestamp_seconds/{print int($2)}' "$f"); st=$(awk '/^harkesh_backup_last_status/{print $2}' "$f")
    age=$(( (NOW - ${ls_:-0}) / 3600 ))
    kv "Dernière réussite ($m)" "il y a ${age} h — statut $st — $(grep -E '^harkesh_backup_(snapshots|last_data_added_bytes|last_duration_seconds)' "$f" | awk '{printf "%s=%s ", $1, $2}')"
    if [ "$m" = backup ] && [ "$age" -gt 26 ]; then finding HIGH "Dernière sauvegarde réussie il y a $age h (> 26 h)"; fi
    if [ "$m" = check ] && [ "$age" -gt 192 ]; then finding MEDIUM "Dernier « restic check » réussi il y a $age h (> 8 jours)"; fi
    [ "$st" = 0 ] && finding MEDIUM "Dernière exécution « $m » de la sauvegarde en échec (au moins une étape)"
  else finding MEDIUM "Métriques de sauvegarde absentes : $f"; fi
done
kv "restic" "$(restic version 2>/dev/null | cut -c1-60 || echo absent)"
if [ "$IS_ROOT" = 1 ]; then
  kv "etcd" "$(du -sh /var/lib/etcd/member/snap/db 2>/dev/null | cut -f1) (base), autres fichiers : $(find /var/lib/etcd -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
  for f in /var/lib/etcd/pre-encryption.db /var/lib/etcd/*.db; do
    [ -f "$f" ] && finding HIGH "Snapshot etcd laissé sur l'hôte : $f ($(date -r "$f" '+%Y-%m-%d')) — s'il date d'avant le chiffrement il contient tous les Secrets en clair (« à supprimer une fois tout validé », _docs/hote.md)"
  done
  [ -d /root/apiserver-hardening ] && finding LOW "/root/apiserver-hardening encore présent ($(find /root/apiserver-hardening -type f | wc -l) fichier(s) de travail du durcissement de l'API server)"
fi
if [ "$QUICK" = 0 ] && [ "$IS_ROOT" = 1 ]; then
  echo "Volumétrie (du, 25 s max par dossier) :"
  for d in /var/lib/containerd /var/lib/docker /var/lib/pelican /var/log /var/backups/harkesh /opt/local-path-provisioner /srv/appdata /mnt/hdd/data /mnt/hdd/cloud_data; do
    [ -d "$d" ] || continue
    printf '  %-34s %s\n' "$d" "$(timeout 25 du -sxh "$d" 2>/dev/null | cut -f1 || true)"
  done
  kv "journald" "$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)"
  kv "Audit API" "$(du -sh /var/log/kubernetes/audit 2>/dev/null | cut -f1)"
fi
echo "Permissions des dossiers de données :"
stat -c '  %A %U:%G %n' /srv/appdata /srv/appdata/* /srv/appdata/matrix/* /srv/jellyfin/config /mnt/hdd /mnt/hdd/* /mnt/hdd/data/* /var/lib/pelican /etc/pelican /var/backups/harkesh /opt/local-path-provisioner 2>/dev/null | cap 45
WW=$(find /srv/appdata /mnt/hdd /mnt/hdd/data /srv/jellyfin /var/lib/pelican /var/backups -maxdepth 2 -type d -perm -0002 ! -perm -1000 2>/dev/null | head -8 | paste -sd' ')
[ -n "$WW" ] && finding LOW "Dossiers de données inscriptibles par tous : $WW"

# ════════════════════════════════════════════════════════════════════════════════════════
section "LOGS"
if have journalctl; then
  kv "Démarrages récents" "$(journalctl --list-boots --no-pager 2>/dev/null | tail -3 | awk '{print $4"_"$5}' | paste -sd' ')"
  echo "Erreurs (priorité ≤ err) sur 24 h, par émetteur :"
  journalctl -p 3 --since "24 hours ago" --no-pager -o short 2>/dev/null | awk '{id=$5; sub(/\[[0-9]+\]:?$/,"",id); sub(/:$/,"",id); c[id]++} END{for(k in c) printf "%7d  %s\n", c[k], k}' | sort -rn | cap 15 | ind
  sub "Noyau ($DAYS j)"
  KLOG=$(journalctl -k --since "$DAYS days ago" --no-pager -o short 2>/dev/null)
  klog_check() { # niveau motif libellé
    local n; n=$(echo "$KLOG" | grep -cE "$2" || true)
    printf '  %-34s %s\n' "$3" "$n"
    if [ "$n" -gt 0 ]; then
      echo "$KLOG" | grep -E "$2" | tail -2 | cut -c1-200 | sed 's/^/      /'
      [ "$1" != NONE ] && finding "$1" "Noyau : $n occurrence(s) « $3 » en $DAYS j"
    fi
  }
  klog_check MEDIUM 'Out of memory|oom-kill|Killed process' "OOM killer"
  klog_check MEDIUM 'NVRM: Xid' "NVIDIA Xid (GPU)"
  klog_check HIGH 'I/O error|blk_update_request|Buffer I/O error|critical medium error' "Erreurs d'E/S disque"
  klog_check HIGH 'EXT4-fs error|XFS.*(error|corrupt)|BTRFS.*error|Remounting filesystem read-only' "Erreurs de système de fichiers"
  klog_check MEDIUM 'nvme.*(timeout|reset|abort)|ata[0-9.]+: .*(error|failed|reset)' "Liens NVMe/SATA instables"
  klog_check HIGH 'Hardware Error|mce: \[Hardware|Machine check' "Erreurs matérielles (MCE)"
  klog_check MEDIUM 'nf_conntrack: table full' "conntrack saturé"
  klog_check LOW 'SYN flooding' "SYN flood détecté"
  klog_check NONE 'segfault at' "segfaults"
  klog_check NONE "$EXP_LAN_IF.*(Link is Down|link down)" "Coupures du lien $EXP_LAN_IF"
  klog_check LOW 'apparmor="DENIED"' "Refus AppArmor"
  unset KLOG
  for u in kubelet containerd docker; do
    sub "Erreurs $u (24 h, messages regroupés)"
    journalctl -u "$u" --since "24 hours ago" --no-pager -o cat 2>/dev/null \
      | grep -E '(^E[0-9]{4} )|level=(error|fatal)|"level":"(error|fatal)"|panic:' \
      | sed -E 's/^E[0-9]{4} [0-9:.]+ +[0-9]+ //; s/time="[^"]*" //; s/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uid>/g; s/[0-9a-f]{64}/<id>/g; s/[0-9]+/N/g' \
      | redact | cut -c1-170 | sort | uniq -c | sort -rn | cap 6 | ind
  done
  sub "sudo ($DAYS j)"
  journalctl -t sudo --since "$DAYS days ago" --no-pager -o cat 2>/dev/null | awk '
    /COMMAND=/{u=$1; c[u]++} /authentication failure|incorrect password|NOT in sudoers/{f++}
    END{for(k in c) printf "  commandes sudo par %s : %d\n", k, c[k]; printf "  échecs d authentification sudo : %d\n", f+0; if (f+0 > 5) exit 4}'
  [ $? = 4 ] && finding LOW "Plus de 5 échecs d'authentification sudo en $DAYS j"
fi
AUD=/var/log/kubernetes/audit
if [ "$HAVE_PY" = 1 ] && [ "$IS_ROOT" = 1 ] && [ -d "$AUD" ]; then
  sub "Audit de l'API Kubernetes (60 000 dernières lignes)"
  read -r -d '' PY_AUDIT <<'PY'
import json, sys, collections, ipaddress
def F(l, m): print("@F|%s|%s" % (l, m))
users = collections.Counter(); execs = collections.Counter(); secrets = collections.Counter(); denied = collections.Counter(); pub = collections.Counter()
first = last = None; n = 0
for line in sys.stdin:
    try: e = json.loads(line)
    except Exception: continue
    n += 1; ts = e.get("requestReceivedTimestamp", ""); first = first or ts; last = ts or last
    u = (e.get("user") or {}).get("username", "?"); o = e.get("objectRef") or {}; verb = e.get("verb", "?")
    code = (e.get("responseStatus") or {}).get("code", 0)
    sysu = u.startswith("system:") and not u.startswith("system:anonymous")
    if not sysu: users[(u, verb)] += 1
    if o.get("subresource") in ("exec", "attach", "portforward", "proxy"): execs[(u, o.get("subresource"), "%s/%s" % (o.get("namespace"), (o.get("name") or "").rsplit("-", 2)[0]))] += 1
    if o.get("resource") == "secrets" and not sysu and verb in ("get", "list", "create", "update", "patch", "delete"): secrets[(u, verb, o.get("namespace") or "*")] += 1
    if code in (401, 403): denied[(u, code, ",".join(e.get("sourceIPs") or []))] += 1
    for ip in e.get("sourceIPs") or []:
        try:
            a = ipaddress.ip_address(ip)
            if not (a.is_private or a.is_loopback or a.is_link_local): pub[(ip, u)] += 1
        except Exception: pass
print("  %d événements, de %s à %s" % (n, first, last))
print("  Comptes non système (utilisateur verbe : nb) : " + "; ".join("%s %s:%d" % (u, v, c) for (u, v), c in users.most_common(14)))
print("  exec / attach / port-forward :")
for (u, s, t), c in execs.most_common(12): print("    %5d  %-28s %-12s %s" % (c, u, s, t))
print("  Accès aux Secrets par des comptes non système (utilisateur, verbe, namespace) :")
for (u, v, ns), c in secrets.most_common(12): print("    %5d  %-45s %-7s %s" % (c, u, v, ns))
print("  Refus 401/403 :")
for (u, code, ip), c in denied.most_common(8): print("    %5d  %-40s %s depuis %s" % (c, u, code, ip))
for (ip, u), c in pub.most_common(5):
    F("HIGH", "L'API Kubernetes a reçu %d requête(s) depuis l'IP publique %s (compte %s) : le port 6443 est joignable hors LAN — à vérifier" % (c, ip, u))
anon = sum(c for (u, _, _), c in denied.items() if u == "system:anonymous")
if anon > 20: F("LOW", "%d requêtes anonymes refusées par l'API : quelque chose sonde le port 6443 (voir les IP ci-dessus)" % anon)
PY
  # shellcheck disable=SC2012
  consume < <(tail -q -n 60000 "$(ls -t "$AUD"/*.log 2>/dev/null | head -1)" 2>/dev/null | python3 -c "$PY_AUDIT" 2>&1)
fi

# ════════════════════════════════════════════════════════════════════════════════════════
section "SECURITY"
sub "Processus"
echo "Top CPU :"; ps -eo pid,user,pcpu,pmem,etimes,comm --sort=-pcpu 2>/dev/null | head -9 | ind
echo "Top mémoire :"; ps -eo pid,user,pcpu,pmem,rss,comm --sort=-rss 2>/dev/null | head -9 | ind
if need_root "inspection de /proc (binaires supprimés, shells sur socket, motifs de reverse shell)"; then
  N_HOST=0; N_K8S=0; N_DOCK=0; DELETED=""; HOSTBIN=""
  RS_RE='(/dev/tcp/|/dev/udp/|(^|[ /])(nc|ncat|netcat) (.* )?-[a-z]*e |ncat .*--(exec|sh-exec)|socat .*(exec|system):|(^|[ /])(ba|z|da)?sh -i( |$)|python[0-9.]* -c .*(socket|pty\.spawn)|perl -e .*[Ss]ocket|php -r .*fsockopen|ruby -rsocket|mkfifo .*(nc|sh) |xmrig|kdevtmpfsi|kinsing|minerd|cpuminer|stratum\+tcp|cryptonight|(^|[ /])(masscan|zmap) )'
  pdesc() { printf '%s « %s »' "$(stat -c %U "/proc/$1" 2>/dev/null)" "$(echo "$2" | redact | cut -c1-140)"; }
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}; exe=$(readlink "$p/exe" 2>/dev/null) || continue
    [ -z "$exe" ] && continue
    cg=""; comm=""
    { cg=$(<"$p/cgroup"); read -r comm < "$p/comm"; } 2>/dev/null
    case "$cg" in *kubepods*) ctx=k8s; N_K8S=$((N_K8S+1)) ;; *docker*) ctx=docker; N_DOCK=$((N_DOCK+1)) ;; *) ctx=hote; N_HOST=$((N_HOST+1)) ;; esac
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-300)
    case "$exe" in
      "/memfd:"*) case "$exe" in *runc*) ;; *) finding HIGH "Processus exécuté depuis la mémoire (memfd, sans fichier) : pid $pid [$ctx] $(pdesc "$pid" "$cmd") — indicateur fort, à vérifier" ;; esac ;;
      *" (deleted)") [ "$ctx" = hote ] && DELETED="$DELETED $comm($pid)" ;;
    esac
    case "$exe" in
      /tmp/*|/var/tmp/*|/dev/shm/*|/run/user/*|/run/shm/*)
        if [ "$ctx" = hote ]; then finding HIGH "Processus de l'hôte lancé depuis un dossier temporaire : pid $pid $exe $(pdesc "$pid" "$cmd") — à vérifier"
        else finding MEDIUM "Processus de conteneur [$ctx] lancé depuis un dossier temporaire : pid $pid $exe $(pdesc "$pid" "$cmd")"; fi ;;
      /usr/*|/bin/*|/sbin/*|/lib/*|/opt/cni/*|/snap/*) ;;
      *) [ "$ctx" = hote ] && HOSTBIN="$HOSTBIN$(stat -c %U "$p" 2>/dev/null) ${exe% (deleted)}"$'\n' ;;
    esac
    if [[ $cmd =~ $RS_RE ]]; then
      finding HIGH "Ligne de commande suspecte (motif reverse shell / mineur / scanner) : pid $pid [$ctx] $(pdesc "$pid" "$cmd") — un seul indicateur ne prouve rien, vérifier le parent et les connexions"
    fi
    case "$comm" in sh|bash|dash|zsh|ash|ksh)
      fd0=$(readlink "$p/fd/0" 2>/dev/null); fd1=$(readlink "$p/fd/1" 2>/dev/null)
      case "$fd0" in socket:*)
        if [ "$fd0" = "$fd1" ]; then
          ppid=$(awk '/^PPid:/{print $2}' "$p/status" 2>/dev/null); pcomm=$(cat "/proc/$ppid/comm" 2>/dev/null)
          case "$pcomm" in sshd*|systemd|containerd-shim*|runc*|dockerd) ;;
            *) finding HIGH "Shell dont l'entrée ET la sortie sont le même socket : pid $pid [$ctx], parent $pcomm($ppid), $(pdesc "$pid" "$cmd") — signature classique d'un shell distant, à vérifier" ;; esac
        fi ;; esac ;;
    esac
  done
  kv "Processus" "hôte=$N_HOST pods=$N_K8S docker=$N_DOCK"
  if [ -n "$DELETED" ]; then
    echo "  Binaires supprimés encore en mémoire (hôte) :$DELETED" | cut -c1-400
    finding LOW "Processus de l'hôte dont le binaire a été remplacé/supprimé (souvent une mise à jour sans redémarrage du service) :$(echo "$DELETED" | cut -c1-200)"
  fi
  echo "Binaires de l'hôte hors /usr /bin /sbin (utilisateur chemin) :"
  echo "$HOSTBIN" | grep -v '^$' | sort | uniq -c | sort -rn | cap 20 | ind
  [ -s /etc/ld.so.preload ] && finding HIGH "/etc/ld.so.preload non vide ($(tr '\n' ' ' < /etc/ld.so.preload | cut -c1-120)) : bibliothèque injectée dans tous les processus — à vérifier"
fi

sub "Persistance (systemd, cron, démarrage)"
# usrmerge : dpkg peut connaître /bin/x alors que le fichier est vu sous /usr/bin/x
owned() { dpkg -S "$1" >/dev/null 2>&1 || dpkg -S "${1#/usr}" >/dev/null 2>&1; }
echo "Unités systemd hors paquets (/etc/systemd/system, /usr/local/lib/systemd) :"
while read -r f; do
  [ -z "$f" ] && continue
  owned "$f" && continue
  exe=$(grep -hsE '^Exec(Start|StartPre|StartPost)=' "$f" | head -2 | redact | paste -sd' ' | cut -c1-150)
  printf '  %s (%s) %s\n' "$f" "$(date -r "$f" '+%Y-%m-%d')" "$exe"
  case "$f" in
    */harkesh-backup*|*/kubelet.service.d/*|*/nvidia-persistenced.service.d/*|*/docker.service.d/*|*/containerd.service.d/*|*/crowdsec*) ;;
    *.service|*.timer|*.socket|*.path) finding LOW "Unité systemd hors paquet et hors référentiel : $f → $exe" ;;
  esac
done < <(find /etc/systemd/system /usr/local/lib/systemd/system -type f \( -name '*.service' -o -name '*.timer' -o -name '*.socket' -o -name '*.path' -o -name '*.conf' \) 2>/dev/null | sort)
echo "Unités utilisateur : $(find /home/*/.config/systemd/user /root/.config/systemd/user /etc/systemd/user -type f 2>/dev/null | paste -sd' ' || true)"
[ -n "$(find /home/*/.config/systemd/user /root/.config/systemd/user -type f 2>/dev/null | head -1)" ] && finding LOW "Unités systemd utilisateur présentes (persistance possible) : $(find /home/*/.config/systemd/user /root/.config/systemd/user -type f 2>/dev/null | paste -sd' ' | cut -c1-200)"
echo "Fichiers modifiés depuis 30 j dans /etc/systemd, /etc/cron*, /etc/profile.d, /etc/pam.d, /etc/ssh, /etc/sudoers.d :"
find /etc/systemd /etc/cron* /etc/profile.d /etc/pam.d /etc/ssh /etc/sudoers.d /etc/ld.so.conf.d /etc/udev/rules.d -type f -mtime -30 -printf '  %TY-%Tm-%Td %p\n' 2>/dev/null | sort -r | cap 25
echo "Timers :"
systemctl list-timers --all --no-legend 2>/dev/null | awk '{print $(NF-1)}' | paste -sd' ' | fold -s -w 150 | ind
echo "cron :"
grep -vE '^[[:space:]]*(#|$)|^(SHELL|PATH|MAILTO)=' /etc/crontab 2>/dev/null | redact | sed 's/^/  crontab: /'
for f in /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/*; do
  [ -f "$f" ] || continue
  case "$f" in */.placeholder) continue ;; esac
  if ! owned "$f"; then
    echo "  hors paquet : $f ($(date -r "$f" '+%Y-%m-%d'))"
    case "$f" in /etc/cron.d/*) grep -vE '^[[:space:]]*(#|$)|^[A-Z_]+=' "$f" 2>/dev/null | redact | cut -c1-160 | sed 's/^/      /' | head -5 ;; esac
    finding LOW "Tâche cron hors paquet : $f"
  fi
done
if [ "$IS_ROOT" = 1 ]; then
  for f in /var/spool/cron/crontabs/*; do
    [ -f "$f" ] || continue
    n=$(grep -cvE '^[[:space:]]*(#|$)' "$f")
    echo "  crontab de $(basename "$f") : $n entrée(s)"
    grep -vE '^[[:space:]]*(#|$)' "$f" | redact | cut -c1-160 | sed 's/^/      /' | head -8
    [ "$n" -gt 0 ] && finding LOW "Crontab utilisateur « $(basename "$f") » ($n entrée(s)) : aucune n'est documentée dans le dépôt (les tâches de l'hôte sont des timers systemd)"
  done
  have atq && [ "$(atq 2>/dev/null | wc -l)" -gt 0 ] && finding LOW "Tâches « at » en file : $(atq | wc -l)"
fi
[ -s /etc/rc.local ] && finding LOW "/etc/rc.local présent ($(grep -cvE '^[[:space:]]*(#|$)' /etc/rc.local) ligne(s) actives)"
for f in /etc/profile.d/* /etc/update-motd.d/*; do [ -f "$f" ] && ! owned "$f" && finding LOW "Script de session hors paquet : $f ($(date -r "$f" '+%Y-%m-%d'))"; done
grep -qsE 'LD_PRELOAD|LD_LIBRARY_PATH' /etc/environment && finding MEDIUM "/etc/environment définit LD_PRELOAD / LD_LIBRARY_PATH"
echo "Exécutables dans /usr/local/bin et /usr/local/sbin : $(find /usr/local/bin /usr/local/sbin -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"

sub "Fichiers sensibles (mode et propriétaire seulement)"
if need_root "permissions des fichiers sensibles"; then
  chk() { # fichier, mode maximal attendu (masque des bits interdits)
    local f=$1 mask=$2 m
    [ -e "$f" ] || return 0
    m=$(stat -c '%a' "$f"); printf '  %-58s %s %s\n' "$f" "$m" "$(stat -c '%U:%G' "$f")"
    if [ $(( 0$m & 0$mask )) -ne 0 ]; then finding MEDIUM "Permissions trop larges sur $f ($m) : contient des secrets"; fi
  }
  for f in /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf /etc/kubernetes/kubelet.conf \
           /etc/kubernetes/enc/encryption-config.yaml /etc/harkesh-backup/env /etc/harkesh-backup/restic-password /etc/pelican/config.yml \
           /etc/crowdsec/local_api_credentials.yaml /etc/crowdsec/online_api_credentials.yaml /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml \
           /root/.ssh/storagebox_ed25519 /root/.kube/config /home/*/.kube/config; do chk "$f" 077; done
  chk /etc/shadow 027; chk /etc/gshadow 027; chk /etc/sudoers 022; chk /etc/passwd 022; chk /etc/kubernetes/enc 077
  BADKEYS=$(find /etc/kubernetes/pki -name '*.key' -perm /077 2>/dev/null | paste -sd' ')
  [ -n "$BADKEYS" ] && finding HIGH "Clés privées de la PKI Kubernetes lisibles par d'autres comptes : $BADKEYS"
  KCOPIES=$(find /root /home /srv /opt /tmp /var/tmp -maxdepth 4 \( -name 'admin.conf' -o -name '*.kubeconfig' -o -name 'kubeconfig*' \) -type f 2>/dev/null | head -8 | paste -sd' ')
  [ -n "$KCOPIES" ] && finding LOW "Copies de kubeconfig hors /etc/kubernetes : $KCOPIES"
  for f in /home/*/.kube/config; do [ -f "$f" ] && finding INFO "kubeconfig présent pour un compte non root : $f (accès cluster-admin sans sudo si c'est une copie d'admin.conf)"; done
  ENVS=$(find /root /home /srv /opt /etc/harkesh-backup -maxdepth 4 -type f \( -name '.env' -o -name '*.env' \) -perm /004 2>/dev/null | head -10 | paste -sd' ')
  [ -n "$ENVS" ] && finding MEDIUM "Fichiers d'environnement lisibles par tous (contenu non lu) : $ENVS"
  WWF=$(find /etc /usr/local/bin /usr/local/sbin /usr/local/lib -xdev -type f -perm -0002 2>/dev/null | head -8 | paste -sd' ')
  [ -n "$WWF" ] && finding HIGH "Fichiers inscriptibles par tous dans /etc ou /usr/local : $WWF"
  TMPX=$(find /tmp /var/tmp /dev/shm -xdev -type f -perm /0111 ! -path '/tmp/pelican/*' 2>/dev/null | head -10 | paste -sd' ')
  [ -n "$TMPX" ] && finding LOW "Fichiers exécutables dans /tmp, /var/tmp ou /dev/shm : $TMPX"
  SHMH=$(find /dev/shm -xdev -name '.*' ! -name '.' 2>/dev/null | head -5 | paste -sd' ')
  [ -n "$SHMH" ] && finding MEDIUM "Fichiers cachés dans /dev/shm : $SHMH — à vérifier"
  if [ "$QUICK" = 0 ]; then
    echo "Binaires SUID/SGID hors paquets (recherche sur /, hors runtimes et données) :"
    SUID=$(timeout 120 find / -xdev \( -path /var/lib/containerd -o -path /var/lib/docker -o -path /var/lib/kubelet -o -path /var/lib/pelican -o -path /run -o -path /proc -o -path /sys -o -path /snap -o -path /opt/local-path-provisioner -o -path /srv -o -path /mnt -o -path /var/backups \) -prune -o -type f -perm /6000 -print 2>/dev/null)
    kv "SUID/SGID trouvés" "$(echo "$SUID" | grep -c . || true)"
    for f in $SUID; do owned "$f" || { echo "  hors paquet : $f ($(stat -c '%a %U' "$f"))"; finding MEDIUM "Binaire SUID/SGID n'appartenant à aucun paquet : $f — à vérifier"; }; done
    echo "Intégrité des paquets de base (dpkg -V : fichiers modifiés depuis l'installation) :"
    DPKGV=$(timeout 90 dpkg -V openssh-server openssh-client sudo login passwd coreutils util-linux bash procps iproute2 libpam-modules libpam-runtime systemd cron 2>/dev/null)
    if [ -n "$DPKGV" ]; then
      echo "$DPKGV" | cap 15 | ind
      BIN_MOD=$(echo "$DPKGV" | awk '$2!="c" && $1 ~ /^..5/ && $NF ~ /^\/(usr\/)?(s?bin|lib[^\/]*)\//{print $NF}' | paste -sd' ' | cut -c1-300)
      [ -n "$BIN_MOD" ] && finding HIGH "Fichiers de paquets système modifiés hors fichiers de configuration : $BIN_MOD — à vérifier (binaire remplacé ?)"
    else echo "  aucun écart"; fi
  else skip "recherche SUID et dpkg -V (--quick)"; fi
fi

# ════════════════════════════════════════════════════════════════════════════════════════
section "FINDINGS"
TOTAL=${#FINDINGS[@]}
for lvl in CRITICAL HIGH MEDIUM LOW INFO; do
  for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
    [ "${f%%|*}" = "$lvl" ] && printf '[%s] %s\n' "$lvl" "${f#*|}"
  done
done | awk '!seen[$0]++'
echo
printf 'TOTAL: %s constat(s) — ' "$TOTAL"
for lvl in CRITICAL HIGH MEDIUM LOW INFO; do
  n=0; for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do [ "${f%%|*}" = "$lvl" ] && n=$((n+1)); done
  printf '%s=%s ' "$lvl" "$n"
done
echo
echo "Rappel : un constat est un indicateur à vérifier, pas une preuve de compromission."

section "SKIPPED"
if [ ${#SKIPPED[@]} -eq 0 ]; then echo "rien"; else printf '%s\n' "${SKIPPED[@]}" | awk '!s[$0]++' | ind; fi

# ════════════════════════════════════════════════════════════════════════════════════════
section "RAW DATA"
sub "ss -tulpn"
ss -H -tulpn 2>/dev/null | awk '{print $1, $5, $NF}' | sed -E 's/users:\(\(//; s/,fd=[0-9]+\)\)?//g; s/\)$//' | grep -v 'docker-proxy' | cap 90 | ind
if [ "$IS_ROOT" = 1 ]; then
  sub "iptables -S (filter, hors chaînes KUBE/CILIUM détaillées)"
  iptables -S 2>/dev/null | grep -vE '^-A (CILIUM|KUBE|ufw-(before|after|user)-(logging|output|forward)|ufw-(not-local|skip|track|logging))' | cap 90 | ind
  sub "iptables -t nat -S (DNAT Docker = ports de jeux réellement redirigés)"
  iptables -t nat -S 2>/dev/null | grep -E 'DNAT|^-P|MASQUERADE' | grep -vE 'CILIUM|KUBE' | cap 60 | ind
  sub "ip6tables -S"
  ip6tables -S 2>/dev/null | grep -vE '^-A (CILIUM|KUBE)' | cap 40 | ind
fi
if [ "$K8S_OK" = 1 ]; then
  sub "kubectl get pods -A (hors Running/Completed sans redémarrage)"
  k get pods -A --no-headers | awk '$4!="Running" && $4!="Completed" || $5+0>0' | cap 50 | ind
  sub "kubectl get svc -A"
  k get svc -A --no-headers | awk '{print $1, $2, $3, $4, $5, $6}' | cap 90 | ind
fi
sub "ps (processus de l'hôte uniquement, hors threads noyau, commandes masquées/tronquées)"
if [ "$IS_ROOT" = 1 ]; then
  for p in /proc/[0-9]*; do
    grep -qsE 'kubepods|docker' "$p/cgroup" && continue
    [ -n "$(readlink "$p/exe" 2>/dev/null)" ] || continue
    printf '%s %s %s\n' "${p#/proc/}" "$(stat -c %U "$p" 2>/dev/null)" "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | redact | cut -c1-110)"
  done | sort -k3 | awk '{k=$2" "$3; c[k]++; l[k]=$0} END{for(k in c) printf "%s%s\n", l[k], (c[k]>1 ? "  (x"c[k]")" : "")}' | sort -n | cap 110 | ind
fi
echo
echo "=== END OF AUDIT ==="
