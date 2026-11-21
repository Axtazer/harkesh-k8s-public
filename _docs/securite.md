[← Sommaire](README.md)


# Sécurité

Vue d'ensemble des protections en place. Le détail des réglages de l'hôte est dans
[Hôte](hote.md), celui des flux réseau en tête de chaque `networkpolicy.yaml`.

| Couche | Protection | Où |
|---|---|---|
| Hôte | SSH par clé uniquement (`AllowUsers flo`, `MaxAuthTries 3`), ufw en `deny` entrant (IPv4 + IPv6), conteneurs de jeux isolés de l'hôte et du LAN (`DOCKER-USER`), unattended-upgrades sans NVIDIA | [hôte](hote.md) |
| API Kubernetes | Secrets chiffrés dans etcd (secretbox), audit des actions sensibles → VictoriaLogs | hôte, `infra/host/patch-apiserver.py` |
| Réseau | NetworkPolicies deny-all sur tous les namespaces applicatifs, seule entrée = cloudflared, Cloudflare Access devant | `*/networkpolicy.yaml` |
| Pods | Pod Security Admission `warn`/`audit` = `restricted` sur chaque Namespace ; securityContext durcis (ci-dessous) ; `automountServiceAccountToken: false` | manifests |
| Exécution | Tetragon : exec de shells / outils réseau dans un conteneur → VictoriaLogs | `argocd/tetragon.yaml` |
| Logs | Tous les conteneurs + audit API dans VictoriaLogs (14 j) | `argocd/victoria-logs.yaml` |

**securityContext** — règle appliquée partout :

- `seccompProfile: RuntimeDefault` (pod) et `allowPrivilegeEscalation: false` (conteneurs) ;
- image non-root (USER numérique vérifié dans la config de l'image) → en plus `runAsNonRoot` +
  `capabilities.drop: ["ALL"]` (authentik, axtazia, flo-pro, shlink, Seerr, lk-jwt-service, n8n,
  axtazer-me, french-breakfast, VictoriaLogs) ;
- images qui démarrent en root puis baissent leurs droits (postgres, mariadb, redis, nextcloud,
  linuxserver/*, synapse, maubot, nginx, ntfy, jellyfin, panel Pelican) : pas de `drop: ALL`
  (CHOWN/SETUID nécessaires au démarrage). vmagent, vmsingle et vlagent restent root mais sans
  aucune capability (données / logs root lus en propriétaire) ;
- exceptions assumées : Wings, cAdvisor et l'agent Tetragon (`privileged`, accès à l'hôte par
  conception), dcgm-exporter (root + `SYS_ADMIN` pour les métriques GPU).

Ce qui reste non conforme au profil `restricted` (dry-run, ne modifie rien) :

```bash
kubectl label --dry-run=server --overwrite ns --all pod-security.kubernetes.io/enforce=restricted 2>&1 | grep Warning
```

**Requêtes utiles (Grafana → Explore → VictoriaLogs)** :

Les événements JSON sont découpés en champs par vlagent (`verb`, `user.username`, `objectRef.resource`,
`process_exec.process.binary`…) : filtrer sur les champs, pas sur le texte brut. Le dashboard Grafana
**Sécurité** reprend ces requêtes (audit API, Tetragon, paquets refusés par Hubble).

```
source:k8s-audit objectRef.resource:secrets                                   # qui a lu / modifié des Secrets
source:k8s-audit objectRef.subresource:in(exec,attach,portforward)            # kubectl exec / attach / port-forward
source:k8s-audit -user.username:~"^system:"                                   # actions humaines (hors comptes système)
kubernetes.container_name:"export-stdout" process_exec.process.binary:*       # shells / outils réseau lancés dans un conteneur (Tetragon)
```

## Audit de l'hôte

[`infra/host/audit/audit-server.sh`](../infra/host/audit/audit-server.sh) contrôle l'hôte **en lecture seule** (aucun
fichier écrit, aucun réglage modifié, aucun secret affiché) par rapport à ce que décrit le dépôt : SSH, comptes,
pare-feu (ufw / iptables / IPv6), conteneurs Docker de Pelican, plan de contrôle, pods privilégiés,
Services hors ClusterIP, Ingress hors dépôt, NetworkPolicies, RBAC, chiffrement etcd, sauvegardes, journaux,
persistance (systemd, cron), et surtout tout ce qui serait joignable **sans passer par Cloudflare**.

```bash
sudo bash infra/host/audit/audit-server.sh 2>&1 | tee /tmp/audit-$(date +%F).txt
# --no-external : aucune requête sortante (IP publique, DNS, test Access, hairpin)
# --quick       : sans les contrôles lents (SUID, dpkg -V, du, échantillon Hubble) ; --days N : profondeur des journaux
```

`audit-server-v2.sh` (même dossier) est le passage ciblé qui a suivi le premier audit du 2026-11-16 : ce qu'un conteneur
de jeu Pelican peut joindre sur l'hôte, les pods et le LAN, ce qui arrive réellement d'Internet (compteurs ufw), utilité
de CrowdSec, restes hors GitOps.

La section `FINDINGS` classe les constats (`CRITICAL` → `INFO`) : chacun est un **indicateur à vérifier**, pas une
preuve. Ce que le script ne peut pas voir est listé dans `CLOUDFLARE / EXPOSITION` (API Cloudflare, redirections et
pare-feu IPv6 de la box, scan depuis l'extérieur). Les valeurs attendues viennent du bloc « Référentiel » en tête du
script : à mettre à jour avec les apps.
