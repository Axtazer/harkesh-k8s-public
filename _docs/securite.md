[← Sommaire](README.md)


# Sécurité

Vue d'ensemble des protections en place. Le détail des réglages de l'hôte est dans
[Hôte](hote.md), celui des flux réseau en tête de chaque `networkpolicy.yaml`.

| Couche | Protection | Où |
|---|---|---|
| Hôte | SSH par clé uniquement (`AllowUsers flo`, `MaxAuthTries 3`), CrowdSec + bouncer iptables (`INPUT` + `DOCKER-USER`), unattended-upgrades sans NVIDIA | [hôte](hote.md) |
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

**CrowdSec** : `cscli decisions list` (bans actifs), `cscli alerts list` (détections locales),
`cscli metrics` (lignes de logs analysées).
