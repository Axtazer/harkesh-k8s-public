[← Sommaire](README.md)

# Hôte (`harkesh`)

Tout ce qui se règle sur la machine elle-même, hors GitOps : configuration initiale (avant
`kubeadm init`), durcissement, puis mises à jour du système et de Kubernetes.

## Configuration initiale (avant `kubeadm init`)

Réglages faits sur `harkesh` hors GitOps — chacun corrige une panne déjà rencontrée.

**DNS (systemd-resolved)** — DoT vers Quad9, **sans** validation DNSSEC locale ni CoreDNS
dans la liste globale :

```bash
# /etc/systemd/resolved.conf : DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net, DNSOverTLS=yes
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

### Pare-feu (ufw)

Tout ce qui n'est pas listé est refusé en entrée, en IPv4 comme en IPv6. Rien n'est ouvert pour le
HTTP : les sites passent par le Cloudflare Tunnel (connexion sortante). Les seuls ports joignables
depuis Internet sont ceux des serveurs de jeux et le SFTP de Wings, redirigés sur la box
(enregistrements DNS non proxifiés `game.mydomain2.fr` / `sftp.mydomain2.fr`, cf. [Cloudflare](cloudflare.md)).

| Port | Source | Rôle |
|---|---|---|
| 22/tcp | LAN `192.168.1.0/24`, VPN de la box `192.168.27.64/27` | SSH |
| 6443/tcp | LAN | API Kubernetes (kubectl depuis un poste) |
| 45000:45010 tcp+udp | partout | serveurs de jeux Pelican (allocations du nœud) |
| 42022/tcp | partout | SFTP de Wings (`system.sftp.bind_port` de `/etc/pelican/config.yml`) |
| 4679, 4680, 5001/tcp | LAN | Eaton IPP (onduleur) |
| 11987/tcp | LAN | CoolerControl |
| tout | `10.0.0.0/8` | pods → hôte (API server, kubelet, node-exporter ; les namespaces applicatifs sont déjà bridés par leurs NetworkPolicies) |

```bash
ufw default deny incoming && ufw default allow outgoing
ufw allow from 192.168.1.0/24 to any port 22 proto tcp comment 'SSH LAN only'
ufw allow from 192.168.27.64/27 to any port 22 proto tcp comment 'SSH via VPN Freebox'
ufw allow from 192.168.1.0/24 to any port 6443 proto tcp comment 'Kubernetes API LAN only'
ufw allow from 10.0.0.0/8 comment 'Allow K8s Pods Pod-to-Host'
ufw allow proto tcp to 0.0.0.0/0 port 45000:45010 && ufw allow proto udp to 0.0.0.0/0 port 45000:45010
ufw allow proto tcp to 0.0.0.0/0 port 42022 comment 'Pelican Wings SFTP'
for p in 4679 4680 5001 11987; do ufw allow from 192.168.1.0/24 to any port $p proto tcp; done   # Eaton IPP, CoolerControl
ufw allow from 192.168.1.0/24 to any port 4679:4680 proto udp
ufw enable
```

- **Pas de règle `172.16.0.0/12` (« Docker to Host »)** : elle ouvrait tous les ports de l'hôte (kubelet,
  API, node-exporter, API Wings, Eaton…) aux serveurs de jeux, qui exécutent du code tiers. Les
  conteneurs n'ont besoin d'aucun service de l'hôte (audit du 2026-11-16).
- **Conteneurs de jeux → LAN** : Docker contourne ufw pour le trafic routé. Les fichiers
  [`infra/host/ufw/`](../infra/host/ufw/) ajoutent dans `DOCKER-USER` le blocage des plages privées
  depuis `pelican0` (les joueurs du LAN restent servis, Internet reste ouvert) :

  ```bash
  cat infra/host/ufw/after.rules.docker-user  >> /etc/ufw/after.rules
  cat infra/host/ufw/after6.rules.docker-user >> /etc/ufw/after6.rules
  ufw reload
  iptables -S DOCKER-USER     # 7 règles, dont 4 DROP -i pelican0
  ```
- **NodePort / LoadBalancer** : servis en eBPF par Cilium **avant** iptables, ufw ne les voit pas. Ne
  pas créer de Service `NodePort` (`kubectl expose --type=NodePort` compris) : tout reste en `ClusterIP`.
  Seule exception, déclarée dans `jellyfin/jellyfin.yaml` : `jellyfin-nodeport` (31788), accès LAN à
  Jellyfin quand Internet est coupé.
- **Redirections sur la box** (Freebox OS, relevé du 2026-11-16) : `45000-45010` tcp + udp et `42022` tcp
  vers harkesh, rien d'autre. Toute nouvelle redirection s'ajoute ici et dans ufw.
- Vérifier ce qui arrive vraiment : `iptables -nvL ufw-user-input` (paquets acceptés par règle) et
  `journalctl -k | grep 'UFW BLOCK'`.

**Pas de CrowdSec ni de fail2ban** (retirés le 2026-11-16) : SSH n'est joignable que du LAN, le HTTP ne
touche jamais l'hôte, et en 8 jours la blocklist n'avait bloqué aucun paquet sur 566 millions examinés,
pour zéro détection locale. Le SFTP de Wings, seul service à mot de passe exposé, n'était de toute façon
pas analysé (aucun parseur). À reconsidérer seulement si SSH est un jour ouvert sur Internet.

### Services de l'hôte hors Kubernetes

| Service | Rôle | Écoute |
|---|---|---|
| `eaton-ipp` (`mc2`) | arrêt propre sur coupure de courant (onduleur Eaton) | 4679, 4680, 5001 — LAN |
| `coolercontrold` | courbes de ventilation | 11987 — LAN |
| `snapd` | uniquement pour `canonical-livepatch` | — |

Pas de Cockpit (console web à mot de passe : contournait « SSH par clé uniquement »), pas de
cloudflared sur l'hôte (le connecteur tourne en pod), pas de libvirt (KubeVirt archivé).

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
