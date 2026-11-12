[← Sommaire](../README.md)

# Kali Linux (3 VM, bureau dans le navigateur)

Trois **vraies VM** Kali Linux (KubeVirt / KVM) avec bureau XFCE, accessibles depuis n'importe quel
navigateur (Windows, macOS, Linux) sur `https://kali-1.mydomain2.fr`, `kali-2` et `kali-3`, derrière
Cloudflare Access. Dans la VM : **root complet** (`sudo` sans mot de passe pour l'utilisateur `kali`),
`apt`, installations persistantes. L'hôte est protégé par l'hyperviseur (KVM) : un compromis de la VM
ne donne pas accès à harkesh.

```
navigateur ─► Cloudflare (WAF → Access Login) ─► tunnel ─► Service kali-N:8444 ─► pod virt-launcher ─► VM (KasmVNC :8444)
```

| Élément | Détail |
|---|---|
| Hyperviseur | KubeVirt v1.9.1 (`argocd/kubevirt.yaml`, `infra/kubevirt/kustomization.yaml` : release officielle + instance locale), `/dev/kvm` de l'hôte (AMD-V) |
| Image | image cloud Kali officielle (`kali.download/cloud-images/current`), préparée par le Job `kali-N-disk-init` |
| Disque | `disk.img` de **40 Go** (sparse, vrai plafond) sur un PVC `local-path` de 50 Gi, SSD système |
| Bureau distant | KasmVNC 1.4.0 (installé au 1er démarrage, SHA256 épinglé), XFCE, 1920×1080, port 8444 |
| Ressources / VM | 4 vCPU, 6 Go de RAM pour l'invité ; pod : 2 CPU et 4 Gi garantis, **pas de limite** (burst CPU, RAM au-delà de 4 Gi prêtée) |
| Provisionnement | cloud-init (`kali/cloudinit.yaml`) : paquets, utilisateur `kali`, KasmVNC, mots de passe |

## Mise en service (première fois)

Déjà fait : applications Cloudflare Access `kali-1/2/3`, item 1Password `kali-credentials`
(champs `password-1/2/3`).

1. Merger : ArgoCD installe KubeVirt (quelques minutes), puis l'application `kali` crée les PVC, les Jobs de
   préparation des disques et les 3 VM (**arrêtées** : `runStrategy: Halted`).
2. Suivre les Jobs (téléchargement ~1,2 Go + extraction ~12 Go) :
   `kubectl -n kali get jobs` puis `kubectl -n kali logs job/kali-1-disk-init`. Attendu : `disk.img` créé.
3. Démarrer une première VM : `kubectl -n kali patch vm kali-1 --type merge -p '{"spec":{"runStrategy":"Always"}}'`.
4. **Le premier démarrage est long (~10-20 min)** : cloud-init installe `kali-desktop-xfce` (plusieurs Go) puis
   KasmVNC. Suivre : `kubectl -n kali get vmi` ; console série : `virtctl console kali-1 -n kali` (virtctl :
   release KubeVirt v1.9.1) ; en cas d'échec : `sudo cloud-init status --long` et `/var/log/cloud-init-output.log`.
5. Ouvrir `https://kali-1.mydomain2.fr` : Access, puis utilisateur `kali` et `password-1`.
6. Démarrer ensuite `kali-2` et `kali-3` de la même façon (ou laisser le planning s'en charger).

> **Non testé de bout en bout** (aucun accès aux miroirs Kali ni au cluster depuis l'environnement de
> rédaction). Points les plus susceptibles de demander un ajustement au premier essai : URL / nom du fichier de
> l'image cloud (variable `KALI_IMAGE_BASE` du Job), démarrage de KasmVNC, annotations HTTPS de l'Ingress.

## Dépannage du premier démarrage

- Provisionnement : `virtctl console kali-N -n kali` (connexion root automatique sur la console série), puis
  `cloud-init status --long` et `grep -iE "^E:|err|fail" /var/log/cloud-init-output.log`.
- Réseau : l'image Kali ne configure aucune interface par DHCP ; c'est `networkdata` (`kali/cloudinit.yaml`, netplan
  → networkd) qui le fait. Symptôme sinon : `eth0` sans adresse, `Temporary failure resolving` dans apt.
- **Rejouer le provisionnement** d'une VM après un échec ou une modification du cloud-init (cloud-init ne rejoue
  rien tout seul) : dans la VM `cloud-init clean --logs && poweroff`, puis
  `kubectl -n kali patch vm kali-N --type merge -p '{"spec":{"runStrategy":"Always"}}'` (le Secret est relu au
  démarrage). Cela ré-exécute tout : paquets, KasmVNC, mots de passe ; le contenu du home est conservé.

## Mots de passe

Un seul Secret `kali-credentials` (1Password). Il est présenté à la VM comme un **disque virtuel** (`CREDS`) ;
le script `/usr/local/sbin/kali-set-password` y lit `password-N` (N = numéro de la VM) et définit le mot de
passe Linux **et** celui de KasmVNC (même mot de passe). Changer un mot de passe : modifier 1Password, attendre
la synchro du Secret, redémarrer la VM puis `sudo kali-set-password`.
Les 3 champs sont lisibles dans chaque VM (root) : ne pas confier une VM à quelqu'un qui ne doit pas
connaître les autres mots de passe (sinon un item 1Password par VM).

## Démarrage / arrêt automatiques

`scheduler.yaml` : deux CronJobs (heure de Paris) qui changent le `runStrategy` des VM (`Always` / `Halted`).

| Action | Quand |
|---|---|
| Démarrage (`kali-start`) | 08:00, lundi et mardi ; mercredi **seulement les semaines ISO impaires** (le job tourne tous les mercredis et se saute lui-même en semaine paire) |
| Arrêt (`kali-stop`) | 17:00, lundi, mardi, mercredi |

- Arrêt **propre** (ACPI, jusqu'à 120 s) : le disque et tout ce qui est installé sont conservés. Les applications
  ouvertes sont fermées : enregistrer avant 17 h.
- `runStrategy` est ignoré par ArgoCD (`applicationset.yaml`), sinon `selfHeal` le remettrait à `Halted`.
- Démarrer / arrêter à la main : `kubectl -n kali patch vm kali-N --type merge -p '{"spec":{"runStrategy":"Always|Halted"}}'`.
- Exception à `automountServiceAccountToken: false` : les jobs appellent l'API ; Role limité aux 3
  `VirtualMachine`, sortie réseau limitée à l'API server.

## Dimensionnement

Par VM : 4 vCPU / 6 Go (invité), pod avec **2 CPU et 4 Gi garantis**, sans limite. Total ×3 : réservé
**6 CPU / 12 Gi** (+ ~0,3 Gi de surcoût par VM) pendant les heures d'ouverture, ×1,5 en pic mémoire.
Les VM étant arrêtées hors planning, la réservation ne dure que 08:00–17:00 (lun-mer). Vérifier la marge de
harkesh dans Grafana avant de tout lancer ; sinon des pods restent `Pending`.
Pas de limite mémoire : une VM gourmande peut peser sur la RAM de l'hôte (alerte à 8 Go). Disque : 3 × 40 Go
au maximum sur le SSD système (le fichier est sparse : il grossit à l'usage).

## Installer des logiciels

Dans la VM (terminal, utilisateur `kali`) : `sudo apt install …`. Tout est conservé entre les arrêts.

- **Claude** : il n'existe pas d'application Claude pour Linux ; utiliser `https://claude.ai` dans Firefox
  (installable comme application depuis Chrome/Chromium : `sudo apt install chromium`). Claude Code (CLI) :
  `sudo apt install nodejs npm && sudo npm install -g @anthropic-ai/claude-code`.
- **Cisco Packet Tracer** (non redistribuable, compte Netacad) : télécharger le `.deb` Linux depuis
  netacad.com dans le navigateur de la VM, puis `sudo apt install ./CiscoPacketTracer*.deb`.

## Réseau et sécurité

- NetworkPolicy du namespace : deny-all, entrée limitée à cloudflared sur 8444, sortie Internet uniquement
  (plages privées bloquées : pas d'accès aux autres apps, au LAN ni aux autres VM). Les Jobs de préparation
  n'ont que HTTPS vers Internet.
- Cloudflare Access (`Login`) sur chaque URL, voir [Cloudflare](../cloudflare.md) ; la VM n'est jamais exposée sans Access.
- Dans la VM, tous les outils fonctionnent (nmap SYN, etc.), mais sur le réseau NAT de la VM : seulement vers
  Internet, jamais vers le LAN ni le cluster.

## Reprise après l'ancienne version (conteneurs)

Les anciens bureaux (conteneurs Kasm) sont supprimés par ArgoCD. Leurs volumes sont protégés (`Prune=false`) :
une fois sûr de ne rien y garder :

```bash
kubectl -n kali delete pvc kali-1-home-pvc kali-2-home-pvc kali-3-home-pvc
kubectl delete pv kali-1-home-pv kali-2-home-pv kali-3-home-pv
rm -rf /srv/appdata/kali-1 /srv/appdata/kali-2 /srv/appdata/kali-3
systemctl disable --now harkesh-kali-usage.timer
rm -f /etc/systemd/system/harkesh-kali-usage.{service,timer} /usr/local/lib/harkesh-kali/harkesh-kali-usage.sh /var/lib/node_exporter/textfile/harkesh_kali.prom
systemctl daemon-reload
```

## Monitoring

Dashboard « Kali (bureaux distants) » (état, RAM, CPU, réseau, SSD système) et alerte RAM > 8 Go par VM
(ntfy). Les alertes génériques (disque `/`, RAM du nœud, OOM, pod bloqué) couvrent le reste.

## Sauvegarde

Les disques VM ne sont pas dans `infra/host/backup/paths.txt` (fichiers de 40 Go, contenu réinstallable).
Pour sauvegarder des données, les copier hors de la VM.
