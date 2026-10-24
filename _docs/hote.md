[← Sommaire](README.md)

# Hôte (`harkesh`)

Tout ce qui se règle sur la machine elle-même, hors GitOps : configuration initiale (avant
`kubeadm init`), durcissement, puis mises à jour du système et de Kubernetes.

## Configuration initiale (avant `kubeadm init`)

Réglages faits sur `harkesh` hors GitOps — chacun corrige une panne déjà rencontrée.

**DNS (systemd-resolved)** — DoT vers Cloudflare, **sans** validation DNSSEC locale ni CoreDNS
dans la liste globale :

```bash
# /etc/systemd/resolved.conf : DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com (+ IPv6), DNSOverTLS=yes
cat > /etc/systemd/resolved.conf.d/dnssec.conf <<'CONF'
[Resolve]
DNSSEC=no
CONF
systemctl restart systemd-resolved
```

> ⚠️ Ne **jamais** créer de drop-in `DNS=10.96.0.10` + `Domains=~cluster.local` : le `DNS=` est
> global, CoreDNS se retrouve interrogé pour tous les domaines (en DoT qu'il ne parle pas, réponses
> sans données DNSSEC) → `DNSSEC validation failed: missing-key`, plus aucun pull d'image
> (`lookup ghcr.io: no such host`), et boucle CoreDNS → lui-même via le `resolv.conf` des pods
> (incident du 2026-10-11). Pour résoudre un service depuis l'hôte : `dig @10.96.0.10 <svc>.<ns>.svc.cluster.local`.

**resolv.conf dédié à kubelet** — systemd-resolved liste plus de 3 serveurs (globaux + DHCP de
la box), kubelet n'en garde que 3 et émet `DNSConfigForming` en boucle :

```bash
printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 9.9.9.9\n' > /etc/kubernetes/resolv.conf
```

**kubelet attend le HDD** — `/mnt/hdd` est monté en `nofail` : sans dépendance, un disque absent au
boot laisse les pods démarrer sur des dossiers vides créés par containerd (bases vierges, assistant
d'installation Nextcloud exposé). Le drop-in [`infra/host/kubelet/10-require-mounts.conf`](../infra/host/kubelet/10-require-mounts.conf)
fait attendre kubelet ; HDD absent = cluster arrêté jusqu'à réparation (voulu) :

```bash
install -D -m 644 infra/host/kubelet/10-require-mounts.conf /etc/systemd/system/kubelet.service.d/10-require-mounts.conf
systemctl daemon-reload                       # pris en compte au prochain démarrage, pas de restart de kubelet
systemctl show kubelet -p RequiresMountsFor   # attendu : RequiresMountsFor=/mnt/hdd
```

À `kubeadm init`, passer `resolvConf: /etc/kubernetes/resolv.conf` dans la `KubeletConfiguration`.
Sur un cluster existant, modifier la **ConfigMap** (sinon `kubeadm upgrade` réécrit la valeur) :

```bash
kubectl -n kube-system get cm kubelet-config -o yaml \
  | sed 's#resolvConf: /run/systemd/resolve/resolv.conf#resolvConf: /etc/kubernetes/resolv.conf#' \
  | kubectl replace -f -
kubeadm upgrade node phase kubelet-config && systemctl restart kubelet
```

**Paquets épinglés** — mis à jour uniquement via la procédure ci-dessous :

```bash
apt-mark hold kubeadm kubelet kubectl containerd.io
```

**Module WireGuard chargé au boot** — utilisé par gluetun (qBittorrent) et le sidecar
`wg-tunnel` de LiveKit ; aucun pod n'a le droit de le charger lui-même (plus d'initContainer privilégié) :

```bash
echo wireguard > /etc/modules-load.d/wireguard.conf && modprobe wireguard
```

Divers : `libvirtd` désactivé (aucune VM ; il surveillait les veth Cilium), `smartmontools`
activé (surveillance SMART du HDD média).

**SSH** — clé uniquement, utilisateur unique :

```bash
cat > /etc/ssh/sshd_config.d/90-hardening.conf <<'CONF'
X11Forwarding no
MaxAuthTries 3
AllowUsers flo
CONF
sshd -t && systemctl reload ssh
```

**unattended-upgrades sans NVIDIA** — une mise à jour du driver en tâche de fond casse le GPU
(`Driver/library version mismatch`) jusqu'au reboot : le driver ne bouge qu'avec la procédure
« Mises à jour de l'hôte » ci-dessous.

```bash
cat > /etc/apt/apt.conf.d/51unattended-nvidia <<'CONF'
Unattended-Upgrade::Package-Blacklist {
    "nvidia-";
    "libnvidia-";
    "linux-modules-nvidia-";
    "xserver-xorg-video-nvidia-";
};
CONF
```

**GPU : GSP désactivé** — sur la GTX 1660 (Turing), le firmware GSP du driver 580 se bloque
(`GSP_RM_CONTROL` timeout puis `Xid 154 … GPU Reset Required` dans `journalctl -k`) : `nvidia-smi`
répond « Unknown Error », plus de NVENC pour Jellyfin, et seul un reboot récupère la carte
(`nvidia-smi --gpu-reset` échoue). Panne du 19/10/2026. Désactivation du GSP, possible uniquement avec
le module **propriétaire** (`modinfo nvidia | grep license` → `NVIDIA`, pas `Dual MIT/GPL`) :

```bash
echo "options nvidia NVreg_EnableGpuFirmware=0" > /etc/modprobe.d/nvidia-gsp.conf
update-initramfs -u && reboot
nvidia-smi -q | grep -i "GSP Firmware"   # → N/A
```

Si le driver plante quand même, `nvidia-persistenced` reste bloqué dans le noyau et retient le reboot
~6 min (90 s par étape d'arrêt) : délai réduit.

```bash
mkdir -p /etc/systemd/system/nvidia-persistenced.service.d
printf '[Service]\nTimeoutStopSec=10s\n' > /etc/systemd/system/nvidia-persistenced.service.d/timeout.conf
systemctl daemon-reload
```

Alerte Grafana « GPU injoignable » (métriques DCGM absentes 10 min). Après reboot :
`kubectl get node harkesh -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'` → `4` (time-slicing).

### Chiffrement etcd + audit de l'API server

Les Secrets sont chiffrés dans etcd (secretbox) et chaque action sensible sur l'API (Secrets,
`exec`, `port-forward`…) est tracée dans `/var/log/kubernetes/audit/`, que le collecteur
VictoriaLogs lit (`source:k8s-audit` dans Grafana). Les flags doivent être posés **à la fois** dans
le manifest statique et dans la ConfigMap `kubeadm-config` (sinon `kubeadm upgrade` les supprime) :
c'est ce que fait [`infra/host/patch-apiserver.py`](../infra/host/patch-apiserver.py) (idempotent).

```bash
# 1. Clé de chiffrement — la sauvegarder dans 1Password (vault k8s-home) : sans elle, une
#    restauration d'etcd est illisible.
install -d -m 700 /etc/kubernetes/enc
cat > /etc/kubernetes/enc/encryption-config.yaml <<CONF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: [secrets]
    providers:
      - secretbox:
          keys:
            - name: key1
              secret: $(head -c 32 /dev/urandom | base64)
      - identity: {}
CONF
chmod 600 /etc/kubernetes/enc/encryption-config.yaml

# 2. Politique d'audit : Metadata seulement (jamais le contenu des Secrets), bruit système exclu
cat > /etc/kubernetes/audit-policy.yaml <<'CONF'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  - level: None
    verbs: ["watch"]
  - level: None
    nonResourceURLs: ["/healthz*", "/readyz*", "/livez*", "/version", "/metrics", "/openapi/*", "/api", "/api/*", "/apis", "/apis/*"]
  - level: None
    userGroups: ["system:nodes"]
  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager", "system:apiserver"]
  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]
      - group: ""
        resources: ["events"]
      - group: "events.k8s.io"
        resources: ["events"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
      - group: "authorization.k8s.io"
        resources: ["subjectaccessreviews", "selfsubjectaccessreviews"]
      - group: "cilium.io"
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/proxy", "services/proxy"]
  - level: None
    verbs: ["get", "list"]
  - level: Metadata
CONF
install -d /var/log/kubernetes/audit

# 3. Sauvegarde etcd (etcdctl du pod etcd, /var/lib/etcd = hostPath) puis patch (manifest + kubeadm-config)
ETCDCTL="kubectl -n kube-system exec etcd-harkesh -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"
$ETCDCTL snapshot save /var/lib/etcd/pre-encryption.db   # à supprimer une fois tout validé
mkdir -p /root/apiserver-hardening && cd /root/apiserver-hardening
cp /etc/kubernetes/manifests/kube-apiserver.yaml kube-apiserver.yaml.bak
kubectl -n kube-system get cm kubeadm-config -o yaml > kubeadm-config.yaml.bak
python3 patch-apiserver.py kube-apiserver.yaml.bak kubeadm-config.yaml.bak .   # script copié depuis infra/host/
kubectl replace -f kubeadm-config.yaml
cp kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml   # kubelet redémarre l'API server
kubectl get --raw /readyz                                               # attendre "ok"

# 4. Réécrire les Secrets existants (chiffrés à la réécriture) puis vérifier
kubectl get secrets -A -o json | kubectl replace -f -
$ETCDCTL get /registry/secrets/monitoring/grafana-admin --print-value-only | head -c 26; echo
# attendu : k8s:enc:secretbox:v1:key1
```

Retour arrière : recopier `kube-apiserver.yaml.bak` dans `/etc/kubernetes/manifests/` et
`kubectl replace -f kubeadm-config.yaml.bak` (garder le provider `identity` tant que des Secrets
chiffrés existent, sinon ils deviennent illisibles).

### CrowdSec (remplace fail2ban)

Détection sur les logs de l'hôte (SSH…) + blocklist communautaire ; le bouncer bloque à la fois
le trafic vers l'hôte (`INPUT`) **et** vers les conteneurs Docker de Pelican (`DOCKER-USER` —
Docker contourne ufw, une IP bannie atteindrait sinon les serveurs de jeux).

```bash
curl -s https://install.crowdsec.net | sh       # dépôt packagecloud
# Ubuntu Pro (ESM) fournit un crowdsec 1.4.x obsolète en priorité 510 : forcer packagecloud
cat > /etc/apt/preferences.d/crowdsec <<'CONF'
Package: crowdsec*
Pin: origin packagecloud.io
Pin-Priority: 1001
CONF
apt update && apt install -y crowdsec crowdsec-firewall-bouncer-iptables
```

- **Port du LAPI : 8081** (8080 est pris par Wings — `cscli` interrogeait Wings et plantait) :
  `listen_uri: 127.0.0.1:8081` dans `/etc/crowdsec/config.yaml`, même port dans
  `/etc/crowdsec/local_api_credentials.yaml` et `api_url` de
  `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`.
- **Chaînes du bouncer** dans ce même fichier : `iptables_chains: [INPUT, DOCKER-USER]`.
- **Clé du bouncer** (non générée si le bouncer est installé avant que crowdsec tourne) :
  `cscli bouncers add cs-firewall-bouncer -o raw` → `api_key:` du yaml, puis
  `systemctl restart crowdsec crowdsec-firewall-bouncer`.
- Vérifier : `cscli bouncers list` (✔️), `iptables -S | grep CROWDSEC_CHAIN` (INPUT + DOCKER-USER),
  `cscli explain --type syslog --log "$(date '+%b %d %H:%M:%S') harkesh sshd[1]: Invalid user admin from 198.51.100.7 port 1 ssh2"`
  (scénarios `ssh-bf` en vert), `cscli decisions list --origin CAPI | head`.
- Puis `systemctl disable --now fail2ban && apt purge -y fail2ban`.

Le SFTP de Wings (2022, redirigé depuis la box) n'est **pas** analysé par CrowdSec (aucun parseur
pour les logs Wings) : il profite seulement de la blocklist et des bans par IP (tous ports).

## Mises à jour de l'hôte

Nœud unique : toute mise à jour du noyau ou du driver coupe tous les services le temps du reboot.

**apt (noyau, driver NVIDIA)** — les paquets K8s/containerd sont `hold`, `full-upgrade` ne les touche pas.

```bash
apt update && apt full-upgrade
dkms status                     # le module nvidia doit être "installed" pour le nouveau noyau
reboot                          # immédiat si le driver NVIDIA a bougé : sinon "Driver/library version
                                # mismatch" et plus aucun pod GPU (Jellyfin, dcgm-exporter) ne démarre
```

Après reboot : `nvidia-smi`, `kubectl get pods -A | grep -vE "Running|Completed"`. Un pod GPU
démarré avant le device plugin reste en `UnexpectedAdmissionError` → le supprimer.

**containerd** — garder la config locale (`SystemdCgroup`, runtime NVIDIA) :

```bash
cp -a /etc/containerd/config.toml /root/containerd-config.toml.bak
apt-mark unhold containerd.io
apt install -o Dpkg::Options::="--force-confold" containerd.io
apt-mark hold containerd.io
diff /root/containerd-config.toml.bak /etc/containerd/config.toml && echo "config intacte"
```

**Kubernetes (patch ou mineure)** — toujours sans l'addon kube-proxy (remplacé par Cilium) :

```bash
apt-mark unhold kubeadm && apt install kubeadm=<version>-1.1 && apt-mark hold kubeadm
kubeadm upgrade plan
kubeadm upgrade apply v<version> --skip-phases=addon/kube-proxy
kubectl -n kube-system get ds kube-proxy        # doit être NotFound
apt-mark unhold kubelet kubectl && apt install kubelet=<version>-1.1 kubectl=<version>-1.1 && apt-mark hold kubelet kubectl
systemctl daemon-reload && systemctl restart kubelet
```

Pour une montée de mineure, changer d'abord le dépôt apt (`pkgs.k8s.io/core:/stable:/v1.XX/deb`).
