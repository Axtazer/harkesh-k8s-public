#!/usr/bin/env bash
# Audit ciblé (V2) : uniquement les contrôles que le premier passage d'audit-server.sh n'a pas pu
# trancher (2026-11-16). Lecture seule : aucun fichier écrit, aucun réglage modifié, aucun secret
# affiché. Le seul contrôle « actif » (section 1) ouvre des connexions TCP de test DEPUIS le réseau
# d'un conteneur de jeu (nsenter dans son namespace réseau, rien n'est exécuté dans le conteneur).
#
# Usage : sudo bash audit-server-v2.sh 2>&1 | tee /tmp/audit-v2-$(date +%F).txt
set -u
export LC_ALL=C LANG=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
[ "$(id -u)" = 0 ] || { echo "À lancer en root : sudo bash $0" >&2; exit 1; }
export KUBECONFIG=/etc/kubernetes/admin.conf
NODE_IP=192.168.1.200
section() { printf '\n=== %s ===\n' "$1"; }
ind() { sed 's/^/  /'; }
cap() { awk -v n="$1" 'NR<=n{print} END{if(NR>n) printf "  … (%d lignes de plus)\n", NR-n}'; }
redact() { sed -E 's/((pass(word|wd)?|secret|token|api[_-]?key|apikey|auth(orization)?|bearer|credential|key)[A-Za-z0-9_-]*["'"'"']?[=: ]+)[^ ]+/\1***/Ig'; }
k() { timeout 30 kubectl --request-timeout=15s "$@" 2>/dev/null; }
have() { command -v "$1" >/dev/null 2>&1; }
is_public() { case "$1" in 10.*|192.168.*|127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|fe80:*|fd*|fc*|::1) return 1 ;; esac; return 0; }

echo "=== SERVER AUDIT V2 ==="
echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')  HOST: $(hostname)  KERNEL: $(uname -r)"

# ─────────────────────────────────────────────────────────────────────────────────────────
section "1. CONTENEUR DE JEU -> HOTE / PODS / LAN"
# Question : un serveur de jeu Pelican (code tiers : mods, plugins) peut-il joindre les services de
# l'hôte, les pods du cluster et le LAN ? La règle ufw « 172.16.0.0/12 -> Anywhere » le laisse penser.
CID=$(docker ps -q 2>/dev/null | head -1)
if [ -n "$CID" ]; then
  PID=$(docker inspect -f '{{.State.Pid}}' "$CID")
  echo "Conteneur testé : $(docker inspect -f '{{.Name}} ({{.Config.Image}})' "$CID"), IP $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$CID")"
  POD_PG=$(k -n authentik get pods -o wide --no-headers | awk '/postgres/{print $6; exit}')
  POD_REDIS=$(k -n argocd get pods -o wide --no-headers | awk '/redis/{print $6; exit}')
  POD_VM=$(k -n monitoring get pods -o wide --no-headers | awk '/vmsingle/{print $6; exit}')
  GW=$(ip -4 route show default | awk '{print $3; exit}')
  probe() { # libellé ip port
    local r=FERME
    if timeout 3 nsenter -t "$PID" -n bash -c "exec 3<>/dev/tcp/$2/$3" 2>/dev/null; then r=OUVERT; fi
    printf '  %-46s %-22s %s\n' "$1" "$2:$3" "$r"
  }
  probe "hôte SSH" $NODE_IP 22
  probe "hôte API Kubernetes" $NODE_IP 6443
  probe "hôte kubelet" $NODE_IP 10250
  probe "hôte etcd" $NODE_IP 2379
  probe "hôte Wings API" $NODE_IP 8080
  probe "hôte Cockpit" $NODE_IP 9090
  probe "hôte node-exporter" $NODE_IP 9100
  probe "hôte Tetragon" $NODE_IP 2112
  probe "hôte Eaton IPP (web)" $NODE_IP 5001
  probe "hôte CoolerControl" $NODE_IP 11987
  probe "hôte via passerelle Docker (Wings API)" 172.18.0.1 8080
  probe "hôte via passerelle Docker (Cockpit)" 172.18.0.1 9090
  probe "ClusterIP API Kubernetes" 10.96.0.1 443
  [ -n "$POD_PG" ] && probe "pod authentik/postgresql" "$POD_PG" 5432
  [ -n "$POD_REDIS" ] && probe "pod argocd/redis" "$POD_REDIS" 6379
  [ -n "$POD_VM" ] && probe "pod monitoring/vmsingle" "$POD_VM" 8428
  [ -n "$GW" ] && { probe "box (LAN) HTTP" "$GW" 80; probe "box (LAN) HTTPS" "$GW" 443; }
  probe "Internet (témoin, doit être OUVERT)" 1.1.1.1 443
else
  echo "  aucun conteneur Docker en cours : démarrer un serveur de jeu puis relancer"
fi
echo "Chaînes concernées (compteurs) :"
iptables -nvL DOCKER-USER 2>/dev/null | ind
iptables -nvL DOCKER-FORWARD 2>/dev/null | cap 14 | ind
echo "bridge-nf-call-iptables=$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)  after.rules ufw : $(grep -c 'DOCKER-USER' /etc/ufw/after.rules 2>/dev/null) mention(s) de DOCKER-USER"

# ─────────────────────────────────────────────────────────────────────────────────────────
section "2. CE QUI ARRIVE REELLEMENT D'INTERNET (compteurs ufw + journaux UFW BLOCK, 7 j)"
echo "Règles ufw utilisateur IPv4 (paquets acceptés par règle) :"
iptables -nvL ufw-user-input 2>/dev/null | awk 'NR>2{printf "  %8s paquets  %s\n", $1, substr($0, index($0,$3))}' | cut -c1-170
echo "Règles ufw utilisateur IPv6 :"
ip6tables -nvL ufw6-user-input 2>/dev/null | awk 'NR>2{printf "  %8s paquets  %s\n", $1, substr($0, index($0,$3))}' | cut -c1-170
echo "Paquets BLOQUES par ufw, par origine / protocole / port de destination :"
{ journalctl -k --since "7 days ago" --no-pager -o cat 2>/dev/null; cat /var/log/ufw.log 2>/dev/null; } | grep 'UFW BLOCK' | awk '
  { src=""; dpt="-"; proto="?"; for(i=1;i<=NF;i++){ if($i ~ /^SRC=/) src=substr($i,5); if($i ~ /^DPT=/) dpt=substr($i,5); if($i ~ /^PROTO=/) proto=substr($i,7) }
    o="INTERNET"; if (src ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|fe80:|f[cd])/) o="PRIVE";
    if (src ~ /^172\.18\./) o="CONTENEUR-JEU"; if (src ~ /^10\./) o="POD";
    c[o" "proto"/"dpt]++; s[o" "src]++ }
  END { for(k in c) printf "%7d  %s\n", c[k], k }' | sort -rn | cap 30 | ind
echo "(si INTERNET apparaît : la box redirige ou laisse passer ce port ; IPv4 = redirection, IPv6 = pare-feu IPv6 de la box ouvert)"
echo "Sources Internet distinctes bloquées : IPv4=$({ journalctl -k --since '7 days ago' --no-pager -o cat 2>/dev/null; } | grep 'UFW BLOCK' | grep -oE 'SRC=[0-9.]+' | cut -d= -f2 | grep -vE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)' | sort -u | wc -l) IPv6=$({ journalctl -k --since '7 days ago' --no-pager -o cat 2>/dev/null; } | grep 'UFW BLOCK' | grep -oE 'SRC=[0-9a-f:]+:[0-9a-f:]+' | cut -d= -f2 | grep -vE '^(fe80|f[cd])' | sort -u | wc -l)"
PUB4=$(curl -4 -s -m 6 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}'); case "$PUB4" in *[!0-9.]*) PUB4="" ;; esac
if [ -n "$PUB4" ]; then
  echo "Test hairpin vers l'IPv4 publique (indicatif) :"
  for p in 42022 45000 45008 5520 9090 31788 30256; do
    if timeout 3 bash -c "exec 3<>/dev/tcp/$PUB4/$p" 2>/dev/null; then echo "  $p/tcp OUVERT"; else echo "  $p/tcp fermé/filtré"; fi
  done
fi

# ─────────────────────────────────────────────────────────────────────────────────────────
section "3. CROWDSEC : SERT-IL A QUELQUE CHOSE ?"
echo "Bouncer actif depuis : $(systemctl show crowdsec-firewall-bouncer -p ActiveEnterTimestamp --value)"
echo "Compteurs complets :"
iptables -nvL CROWDSEC_CHAIN 2>/dev/null | ind
ip6tables -nvL CROWDSEC_CHAIN 2>/dev/null | ind
iptables -nvL INPUT 2>/dev/null | sed -n '1,5p' | ind
echo "Fichiers d'acquisition : $(ls /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.d/ 2>/dev/null | tr '\n' ' ')"
echo "Journal SFTP de Wings (échecs d'authentification, 7 j) :"
k -n wings logs deploy/wings --since=168h --tail=20000 | grep -ciE 'sftp.*(fail|invalid|denied|incorrect)|failed.*(password|credentials)' | sed 's/^/  lignes : /'
k -n wings logs deploy/wings --since=168h --tail=20000 | grep -iE 'sftp.*(fail|invalid|denied|incorrect)|failed.*(password|credentials)' | tail -3 | redact | cut -c1-220 | ind
echo "Wings écrit-il un journal sur l'hôte ? $(ls -la /var/log/pelican 2>/dev/null | awk 'NR>1{print $5, $9}' | tr '\n' ' ')"

# ─────────────────────────────────────────────────────────────────────────────────────────
section "4. SSH : BLOC MATCH ET COMPTE media"
grep -rnE -A8 '^[[:space:]]*Match' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | cap 30 | ind
echo "StrictModes : $(sshd -T 2>/dev/null | awk '$1=="strictmodes"{print $2}')"
echo "Configuration effective pour media :"
sshd -T -C user=media,host=x,addr=192.168.1.50 2>/dev/null | grep -E '^(allowusers|forcecommand|chrootdirectory|passwordauthentication|pubkeyauthentication|authorizedkeysfile|allowtcpforwarding|permittty) ' | ind
echo "Compte : $(getent passwd media)  mot de passe : $(passwd -S media 2>/dev/null | awk '{print $2}')"
stat -c '  %A %U:%G %n' /mnt/hdd/media /mnt/hdd/media/.ssh /mnt/hdd/media/.ssh/authorized_keys 2>/dev/null
echo "Connexions de media sur 30 j : $(journalctl -t sshd -t sshd-session --since '30 days ago' --no-pager -o cat 2>/dev/null | grep -c 'for media ')"
echo "Clé de root (/root/.ssh/id_ed25519.pub) : $(ssh-keygen -lf /root/.ssh/id_ed25519.pub 2>/dev/null)"
echo "Hôtes de /root/.ssh/config :"; grep -hE '^[[:space:]]*(Host|HostName|User|Port|IdentityFile) ' /root/.ssh/config 2>/dev/null | ind

# ─────────────────────────────────────────────────────────────────────────────────────────
section "5. SERVICES DE L'HOTE HORS DEPOT"
for u in cockpit.socket cockpit.service cloudflared.service cloudflared-update.timer wol-http.service caddy.service libvirtd.service libvirtd.socket lxd-installer.socket iscsid.socket coolercontrold.service eaton-ipp.service snapd.service ModemManager.service wpa_supplicant.service udisks2.service; do
  printf '  %-28s enabled=%-10s active=%s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null | head -1)" "$(systemctl is-active "$u" 2>/dev/null | head -1)"
done
echo "Paquets : $(dpkg -l 2>/dev/null | awk '$1=="ii" && $2 ~ /^(cockpit|caddy|cloudflared|libvirt-daemon|qemu-system|lxd|coolercontrol|fail2ban)/{printf "%s ", $2}')"
echo "Snaps : $(snap list 2>/dev/null | awk 'NR>1{printf "%s ", $1}')"
echo "Cockpit : connexions sur 30 j = $(journalctl -u cockpit --since '30 days ago' --no-pager 2>/dev/null | grep -ciE 'session opened|New connection')  conf : $(grep -vsE '^[[:space:]]*(#|$)' /etc/cockpit/cockpit.conf | tr '\n' ' ')"
echo "cloudflared sur l'hôte : $(command -v cloudflared || echo absent) $(cloudflared --version 2>/dev/null | head -1)"
echo "  fichiers (noms seulement) : $(ls -A /etc/cloudflared /root/.cloudflared /home/flo/.cloudflared 2>/dev/null | tr '\n' ' ')"
echo "wol-http : $(ls -la /opt/wol-service 2>/dev/null | awk 'NR>1{print $1, $3, $9}' | tr '\n' ' ') — écoute : $(grep -hoE '(port|PORT)[ =:]+[0-9]+|0\.0\.0\.0|127\.0\.0\.1' /opt/wol-service/wol_http.py 2>/dev/null | sort -u | tr '\n' ' ')"
echo "Eaton IPP — script lancé en root par sudo NOPASSWD, il ne doit pas être modifiable par eaton-ipp :"
for p in /usr/local/eaton /usr/local/eaton/IntelligentPowerProtector /usr/local/eaton/IntelligentPowerProtector/bin /usr/local/eaton/IntelligentPowerProtector/bin/shutdown.sh; do stat -c '  %A %U:%G %n' "$p" 2>/dev/null; done
echo "Compte caddy (propriétaire apparent de dossiers de données) : $(getent passwd caddy)"

# ─────────────────────────────────────────────────────────────────────────────────────────
section "6. DDNS CLOUDFLARE (crontab de flo)"
F=/usr/local/bin/cf-ddns.sh
if [ -e "$F" ]; then
  stat -c '%A %U:%G %n (%s octets, modifié %y)' "$F"
  echo "Noms DNS cités : $(grep -oE '[A-Za-z0-9.-]+\.(axtazer\.me|castaldo\.fr|croissante\.dev)' "$F" | sort -u | tr '\n' ' ')"
  echo "Jeton écrit en dur dans le script : $(grep -ciE '(token|api_key|apikey|bearer)[^=]*=[[:space:]]*["'"'"']?[A-Za-z0-9_-]{20,}' "$F") ligne(s) ; fichiers lus : $(grep -oE '(source|\.|cat) +[~/][^ ;"]+' "$F" | tr '\n' ' ')"
  for h in $(grep -oE '[A-Za-z0-9.-]+\.(axtazer\.me|castaldo\.fr|croissante\.dev)' "$F" | sort -u); do
    echo "  $h -> $(getent ahostsv4 "$h" | awk '{print $1}' | sort -u | tr '\n' ' ') (IP publique : ${PUB4:-?})"
  done
else
  echo "$F absent : la tâche cron de flo tourne dans le vide toutes les 5 min"
fi
crontab -u flo -l 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' | redact | ind

# ─────────────────────────────────────────────────────────────────────────────────────────
section "7. WINGS"
echo "Clés non secrètes de /etc/pelican/config.yml :"
grep -nE '^[[:space:]]*(host|port|bind_port|bind_address|address|enabled|ssl|cert|remote|read_only|trusted_proxies|allowed_origins|allow_cors_private_network|disable_remote_download|ignore_panel_config_updates|network|name|interface|ispn|driver|dns|v4|v6|subnet|gateway):' /etc/pelican/config.yml 2>/dev/null | grep -viE 'token|key|pass|secret' | cut -c1-120 | cap 45 | ind
echo "Réseau Docker pelican_nw : $(docker network inspect pelican_nw -f 'ipv6={{.EnableIPv6}} internal={{.Internal}} icc={{index .Options "com.docker.network.bridge.enable_icc"}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)"

# ─────────────────────────────────────────────────────────────────────────────────────────
section "8. KUBERNETES : RESTES HORS GITOPS"
echo "Service media/jellyfin-nodeport :"
k -n media get svc jellyfin-nodeport -o jsonpath='  créé={.metadata.creationTimestamp} gestionnaire={.metadata.managedFields[0].manager} suivi-argocd={.metadata.annotations.argocd\.argoproj\.io/tracking-id} selector={.spec.selector}{"\n"}'
echo "  réponse depuis l'hôte : $(curl -s -o /dev/null -m 4 -w '%{http_code}' http://$NODE_IP:31788/health 2>/dev/null) (000 = bloqué par la NetworkPolicy ; test LAN à faire depuis un autre poste)"
echo "Namespace axtazia : $(k get all,cm,secret,pvc,networkpolicy,ingress -n axtazia --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
echo "IngressClass nginx : $(k get ingressclass nginx -o jsonpath='créé={.metadata.creationTimestamp}')"
echo "Webhooks d'admission : $(k get validatingwebhookconfigurations,mutatingwebhookconfigurations --no-headers | awk '{print $1}' | tr '\n' ' ')"
echo "ClusterRoles/Bindings orphelins (nginx, kubevirt, cdi, kali) : $(k get clusterroles,clusterrolebindings --no-headers | awk '{print $1}' | grep -ciE 'nginx|kubevirt|cdi\.|kali')"
echo "CRD kubevirt/cdi : $(k get crd --no-headers | grep -ciE 'kubevirt|cdi\.')  device plugins kubelet : $(ls /var/lib/kubelet/device-plugins 2>/dev/null | tr '\n' ' ')"
echo "ServiceAccounts hors dépôt avec jeton monté dans argocd/kube-system : (non vérifié ici)"
echo ".kubelet-keep : $(stat -c '%s octets, %U, modifié %y' /etc/kubernetes/manifests/.kubelet-keep 2>/dev/null)"
echo "NetworkPolicies du namespace argocd :"; k -n argocd get networkpolicy --no-headers | awk '{print "  "$1, $2}'
echo "Erreurs cloudflared (24 h, regroupées) :"
k -n cloudflare-tunnel-ingress-controller logs deploy/controlled-cloudflared-connector --since=24h --tail=4000 | grep ' ERR ' | sed -E 's/^[0-9TZ:.-]+ //; s/connIndex=[0-9]+//; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/<ip>/g; s/[0-9a-f]{8}-[0-9a-f-]{27}/<id>/g; s/[0-9]+/N/g' | cut -c1-170 | sort | uniq -c | sort -rn | cap 6 | ind

# ─────────────────────────────────────────────────────────────────────────────────────────
section "9. RESTES SUR L'HOTE"
echo "Conteneurs Docker arrêtés et volumes :"
docker ps -a --filter status=exited --format '  {{.Names}} | {{.Image}} | {{.Status}}' 2>/dev/null
docker volume ls --format '  volume {{.Name}}' 2>/dev/null | cap 15
docker system df 2>/dev/null | ind
echo "Dossiers de travail dans /root : $(find /root -maxdepth 1 -mindepth 1 -not -name '.*' -printf '%f(%TY-%Tm) ' 2>/dev/null)"
echo "Sauvegardes de configuration SSH de root : $(ls /root/.ssh/config.* 2>/dev/null | tr '\n' ' ')"
echo "fusermount3 : $(dpkg -S /bin/fusermount3 /usr/bin/fusermount3 2>&1 | tr '\n' ' ') — dpkg -V fuse3 : $(dpkg -V fuse3 2>&1 | tr '\n' ' ' || true)(vide = intact)"
echo "Membres lxd / libvirt : $(getent group lxd libvirt | tr '\n' ' ')"
echo "Mises à jour de sécurité en attente : $(apt list --upgradable 2>/dev/null | grep -- '-security' | cut -d/ -f1 | tr '\n' ' ')"

# ─────────────────────────────────────────────────────────────────────────────────────────
section "10. /mnt/hdd (95 %)"
timeout 120 du -xh --max-depth=1 /mnt/hdd 2>/dev/null | sort -rh | cap 12 | ind
timeout 120 du -xh --max-depth=1 /mnt/hdd/media 2>/dev/null | sort -rh | cap 12 | ind
echo "Blocs réservés root : $(tune2fs -l /dev/sda1 2>/dev/null | awk -F: '/Reserved block count|Block size/{gsub(/ /,"",$2); printf "%s=%s ", $1, $2}')"

echo
echo "=== END OF AUDIT V2 ==="
