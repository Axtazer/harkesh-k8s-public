# Migration de l'historique Prometheus vers VictoriaMetrics (vmctl)

Procédure manuelle à exécuter **entre le merge de PR1 (#395) et le merge de PR2 (#396)**.
Ne touche pas au repo Git — actions `kubectl`/`vmctl` directes sur le cluster, hors GitOps.

Pré-requis : PR1 mergée, `victoria-metrics-k8s-stack` synced et Healthy dans ArgoCD (vmsingle + vmagent up).

## 1. Localiser le data dir Prometheus (emptyDir)

Prometheus tourne sans PV (emptyDir) — le data dir est sous `/var/lib/kubelet/pods/<uid-pod>/volumes/`.

```bash
# Récupérer le nom du pod Prometheus et son UID
POD=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
POD_UID=$(kubectl -n monitoring get pod "$POD" -o jsonpath='{.metadata.uid}')
echo "$POD / $POD_UID"

# Localiser le volume emptyDir contenant les données Prometheus (nom de volume "prometheus-<statefulset>-db" ou similaire)
sudo find /var/lib/kubelet/pods/"$POD_UID"/volumes/kubernetes.io~empty-dir/ -maxdepth 1 -type d
```

Le dossier retenu est celui contenant un sous-répertoire `wal/` et des dossiers `01H.../` (blocks TSDB) — généralement nommé `prometheus-<release>-prometheus-db` ou `prometheus--db`.

## 2. Snapshot propre avant copie

### Option A — API admin (si `--web.enable-admin-api` actif)

Vérifier si le flag est déjà présent :

```bash
kubectl -n monitoring get pod "$POD" -o jsonpath='{.spec.containers[*].args}' | tr ',' '\n' | grep enable-admin-api
```

Si absent, l'ajouter temporairement via les values ArgoCD de `kube-prometheus-stack` (`prometheus.prometheusSpec.enableAdminAPI: true`), commit + sync, puis :

```bash
kubectl -n monitoring port-forward pod/"$POD" 9090:9090 &
curl -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot
# → renvoie {"status":"success","data":{"name":"<snapshot-dir>"}}
kill %1
```

Le snapshot est créé dans `<data-dir>/snapshots/<snapshot-dir>/` à l'intérieur du même emptyDir — donc localisable avec la même commande `find` que l'étape 1.

**Ne pas oublier de revert `enableAdminAPI` après la migration** (surface d'attaque inutile en temps normal).

### Option B — pas de flag admin-api (alternative sans redéploiement)

Prometheus compacte ses blocks toutes les 2h (blocks finalisés = immuables, safe à copier à chaud). Copier uniquement les blocks finalisés, pas le `wal/` courant (non consistant à chaud) :

```bash
sudo rsync -av --exclude 'wal/' --exclude 'chunks_head/' \
  /var/lib/kubelet/pods/"$POD_UID"/volumes/kubernetes.io~empty-dir/<data-dir>/ \
  /tmp/prometheus-snapshot/
```

Cela perd les dernières ~2h de données (dernier bloc non compacté), acceptable pour une migration d'historique.

## 3. Copier le snapshot en local (si option A)

```bash
sudo cp -r /var/lib/kubelet/pods/"$POD_UID"/volumes/kubernetes.io~empty-dir/<data-dir>/snapshots/<snapshot-dir> \
  /tmp/prometheus-snapshot
sudo chown -R $(whoami) /tmp/prometheus-snapshot
```

## 4. Lancer vmctl (mode prometheus)

Récupérer l'adresse du Service vmsingle créé par `victoria-metrics-k8s-stack` :

```bash
kubectl -n monitoring get svc | grep vmsingle
# ex: vmsingle-victoria-metrics-k8s-stack   ClusterIP   ...   8428/TCP
```

Port-forward pour lancer vmctl depuis l'extérieur du cluster :

```bash
kubectl -n monitoring port-forward svc/vmsingle-victoria-metrics-k8s-stack 8428:8428 &
```

Lancer vmctl (image officielle, pas d'install locale nécessaire) :

```bash
docker run --rm --network host \
  -v /tmp/prometheus-snapshot:/snapshot \
  victoriametrics/vmctl:latest prometheus \
  --prom-snapshot=/snapshot \
  --vm-addr=http://localhost:8428 \
  --vm-concurrency=2
```

Vérifier la progression dans les logs (`vmctl` affiche un pourcentage et le nombre de séries importées). La commande est idempotente — relançable en cas d'interruption.

## 5. Vérifier dans Grafana

- Ouvrir un dashboard existant (ex. "Docker Containers (cAdvisor)"), datasource VictoriaMetrics
- Étendre la plage temporelle à 30 jours (ou à la rétention réelle de l'ancien Prometheus, 10j)
- Vérifier que des données apparaissent **avant** la date de bascule (preuve que l'historique a été importé, pas seulement les nouvelles données scrapées par vmagent)
- Comparer un point précis (ex. RAM d'un container à une date passée) entre l'ancien Grafana (encore branché sur Prometheus) et le nouveau (VictoriaMetrics) pour valider la cohérence

Une fois validé → merger PR2 (#396).
