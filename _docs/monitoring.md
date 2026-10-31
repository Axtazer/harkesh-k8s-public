[← Sommaire](README.md)


# Monitoring (Grafana)

Grafana (`https://grafana.mydomain.fr`) est le sous-chart de `victoria-metrics-k8s-stack`
(`argocd/victoria-metrics-k8s-stack.yaml`). Sa base est un `emptyDir` : **tout ce qui est fait en
clic dans l'UI est perdu au redémarrage du pod**. Dashboards, datasources (et plus tard alertes)
sont provisionnés depuis le dépôt via les sidecars (ConfigMaps labellisées `grafana_dashboard` /
`grafana_datasource`).

**Datasources** : `prometheus` (VictoriaMetrics, par défaut), `victorialogs`, `cloudflare-infinity`.

**Dashboards** — liste et versions dans `monitoring/dashboards/generate.py`, rangés en dossiers
via l'annotation `grafana_folder` :

| Dossier | Dashboards |
|---|---|
| Serveur | Serveur harkesh (maison : CPU, RAM, PSI, NVMe + `/mnt/hdd`, réseau, températures, sauvegardes restic), Node Exporter Full |
| Kubernetes | Kubernetes harkesh (maison : pods, restarts, CrashLoop, utilisé vs requests/limits par namespace, throttling), dotdc Views (global, namespaces, nodes, pods) + System (API server, CoreDNS) |
| GPU | NVIDIA DCGM Exporter |
| Jeux | Serveurs de jeux (Pelican) (maison : conteneurs Docker via cAdvisor) |
| Monitoring | VictoriaMetrics single-node, vmagent, operator, VictoriaLogs single-node |
| Sécurité | Sécurité (maison : audit API — exec, Secrets, refus, violations Pod Security, actions humaines ; exécutions Tetragon ; paquets refusés Hubble) |
| Cloudflare | Cloudflare DNS Analytics (datasource Infinity) |

Aucun dashboard ne dépend de recording rules (vmalert est désactivé ; le sync-job du chart, qui
téléchargeait dashboards et VMRules depuis les branches `master` de GitHub, est coupé). Les
histogrammes `apiserver_*_bucket` sont volontairement droppés au scrape ; les dashboards utilisent les moyennes (`_sum` / `_count`), toujours disponibles.

**Ajouter / modifier un dashboard** (jamais d'édition à la main des `grafana-dashboards-*.yaml`) :

```bash
# grafana.com : ajouter (nom, dossier, ("gnet", id, révision)) dans DASHBOARDS
# maison : éditer/ajouter monitoring/dashboards/<nom>.json (export JSON de Grafana, uid fixe)
python3 monitoring/dashboards/generate.py          # régénère les ConfigMaps
python3 monitoring/dashboards/generate.py --check  # ce que fait la CI (validate)
```

**Vérifier après un sync** :

```bash
kubectl -n monitoring logs deploy/victoria-metrics-k8s-stack-grafana -c grafana-sc-dashboard --tail=50
kubectl -n monitoring logs deploy/victoria-metrics-k8s-stack-grafana -c grafana --since=10m | grep -iE 'level=(error|warn)'
```

## Alertes (Grafana → ntfy)

Seul Grafana alerte (alertmanager et vmalert désactivés). Tout est provisionné par
`monitoring/grafana-alerting.yaml` (sidecar `grafana_alert`) : règles dans le dossier Grafana
**Alertes**, notifications sur le topic ntfy **`grafana`** via l'URL interne
`http://ntfy.ntfy.svc.cluster.local` (fonctionne même si le tunnel Cloudflare est coupé).

| Niveau | ntfy | Rappel |
|---|---|---|
| 🚨 `critical` | priorité 5 (urgent) | toutes les 4 h |
| ⚠️ `warning` | priorité 3 | toutes les 12 h |
| ✅ résolu | priorité 2 | — |

Les alertes de même nom sont regroupées (une notification pour plusieurs pods ou disques).

| Groupe | Règles (seuil → niveau) |
|---|---|
| Nœud | disque `/`, `/boot` > 85 % ⚠️ / > 95 % 🚨 ; HDD `/mnt/hdd` > 90 % ⚠️ / > 97 % 🚨 ; disque plein dans < 24 h ⚠️ ; RAM disponible < 10 % ⚠️ / < 5 % 🚨 ; OOM kill ⚠️ ; load 15 min > 2 × cœurs ⚠️ ; CPU > 85 °C ⚠️ / > 95 °C 🚨 ; NVMe > 70 °C ⚠️ ; GPU > 83 °C ⚠️ / > 90 °C 🚨 ; GPU injoignable (métriques DCGM absentes 10 min) ⚠️ |
| Kubernetes | CrashLoopBackOff 10 min ⚠️ ; > 5 redémarrages en 1 h ⚠️ ; pod Pending/Failed 15 min (hors Jobs) ⚠️ ; Deployment / StatefulSet incomplet 15 min ⚠️ |
| Monitoring | cible de scrape down 10 min ⚠️ ; plus aucune métrique node-exporter 🚨 |
| Sauvegardes | dernière sauvegarde restic réussie > 26 h ⚠️ ; dernière vérification > 8 jours ⚠️ ; métriques `harkesh_backup_*` absentes 1 h ⚠️ ; fichier textfile illisible ⚠️ |
| Exposition | site public KO 5 min 🚨 (blackbox-exporter : mydomain2.fr, mydomain.fr, auth, ntfy, nas — hors Cloudflare Access) ; certificat < 14 jours ⚠️ |

- Token : item 1Password `grafana-ntfy-token` (champ `token`, droit d'écriture sur le topic `grafana`)
  → variable d'env `NTFY_TOKEN` de Grafana.
- Rien en clic dans l'UI : base Grafana en `emptyDir`, silences et modifications perdus au redémarrage.
  Pour couper une alerte : modifier la règle dans le dépôt. Dans ces fichiers, Grafana interpole les
  variables d'environnement : un `$` littéral s'écrit `$$`.
- Tester l'envoi : Grafana → Alerting → Contact points → `ntfy` → Test.
- Vérifier : `kubectl -n monitoring logs deploy/victoria-metrics-k8s-stack-grafana -c grafana-sc-alerts --tail=20`
  puis Grafana → Alerting → Alert rules (27 règles, dossier Alertes).
