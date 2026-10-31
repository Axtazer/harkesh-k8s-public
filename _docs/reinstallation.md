[← Sommaire](README.md)


# Réinstallation complète

Étape 0 : [configuration de l'hôte](hote.md) (DNS, kubelet, chiffrement etcd, CrowdSec…), à faire avant `kubeadm init`.

## Prérequis

- Kubernetes (kubeadm)
- `helm`, `kubectl`, `kubectl krew`, `kubectl neat`


## 1. Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
```

> Même version que `infra/cilium/gateway-api-crds.yaml` (Application qui les reprend ensuite, suivie par Renovate).

## 2. Cilium (CNI + Gateway API)

Depuis un clone du dépôt, avec les **mêmes chart et values** que `argocd/cilium.yaml` (qui reprend la release ensuite) :

```bash
helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium --version 1.20.3 \
  -n kube-system -f infra/cilium/values.yaml
```

> `k8sServiceHost`/`k8sServicePort` sont **obligatoires** sans kube-proxy : sinon l'agent cherche l'API
> sur la ClusterIP `10.96.0.1`, que rien ne traduit avant son propre démarrage → aucun réseau de pod.
> Mêmes valeurs que `infra/cilium/values.yaml` (IP du nœud ; à adapter si elle change).

Cilium remplace kube-proxy (`kubeProxyReplacement=true`) : le DaemonSet `kube-proxy` posé par `kubeadm init`
est inutile. À la réinstallation, `kubeadm init --skip-phases=addon/kube-proxy` ; sur le cluster existant, après
avoir vérifié `cilium status | grep KubeProxyReplacement` (→ `True`) :

```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy
# les règles iptables résiduelles disparaissent au prochain reboot du nœud
```

> `kubeadm upgrade apply` recrée l'addon kube-proxy sauf `--skip-phases=addon/kube-proxy`.

> **local-path-provisioner** (StorageClass `local-path`, utilisée par les PVC n8n, Pelican et vmsingle) n'est
> pas à installer à la main : `argocd/local-path-provisioner.yaml` applique les manifests upstream, déployé par
> `root` à l'étape 4. Ce n'est **pas** la StorageClass par défaut du cluster (les PV/PVC hostPath utilisent
> `storageClassName: ""`), ne pas la passer par défaut.

## 3. 1Password Connect (Secrets d'accès)

Connect + operator sont déployés par ArgoCD (`argocd/onepassword-connect.yaml`, étape 4). Seuls les deux Secrets
d'accès sont créés à la main (jamais dans Git). Récupérer `1password-credentials.json` et le token depuis
1Password → Intégrations → Connect Servers :

```bash
kubectl create namespace 1password
kubectl -n 1password create secret generic op-credentials \
  --from-file=1password-credentials.json=/tmp/1password-credentials.json
read -rs OP_TOKEN && kubectl -n 1password create secret generic onepassword-token --from-literal=token="$OP_TOKEN"
unset OP_TOKEN
rm /tmp/1password-credentials.json
```

> Ces deux Secrets doivent exister **avant** que `root` déploie l'Application `onepassword-connect` (étape 4) :
> sans eux, Connect ne démarre pas et aucun `OnePasswordItem` ne produit de Secret.

## 4. ArgoCD (GitOps)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  --version 10.10.5 -f infra/argocd/values.yaml   # mêmes chart/values que argocd/argocd.yaml (voir ci-dessous)
```

> ArgoCD est ensuite **auto-géré** : `argocd/argocd.yaml` (déployé par `root`) applique le même chart avec
> `infra/argocd/values.yaml`. La version du chart est suivie par Renovate (manuel). Ne plus faire de `helm upgrade`
> à la main — modifier `values.yaml` / `targetRevision` dans git.

CLI et connexion repo (HTTPS, comme tous les manifests ; PAT GitHub en lecture seule sur `harkesh-k8s`) :

```bash
curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
argocd login argocd.mydomain.fr --username admin --grpc-web
argocd repo add https://github.com/Axtazer/harkesh-k8s --username Axtazer --password <PAT> --grpc-web
```

Bootstrap de l'app-of-apps `root` (lit le dossier `argocd/`) :

```bash
kubectl apply -f argocd/root-app.yaml
```

`root` déploie ensuite automatiquement :
- l'ApplicationSet `cluster-apps` (`argocd/applicationset.yaml`), qui crée une Application par dossier listé
  (`authentik`, `axtazer-me`, `bots`, `flo-pro`, `french-breakfast`, `jellyfin`, `livekit`, `matrix`, `media-stack`, `monitoring`, `nextcloud`, `ntfy`, `pelican`, `root-panel`, `shlink`) ;
- les Applications Helm dédiées : `argocd/argocd.yaml` (ArgoCD lui-même), `argocd/n8n.yaml`,
  `argocd/victoria-metrics-k8s-stack.yaml`, `argocd/dcgm-exporter.yaml`, `argocd/k8s-device-plugin.yaml`,
  `argocd/metrics-server.yaml`, `argocd/prometheus-operator-crds.yaml`, `argocd/local-path-provisioner.yaml`,
  `argocd/victoria-logs.yaml`, `argocd/tetragon.yaml`, `argocd/onepassword-connect.yaml` (Secrets d'accès : étape 3) ;
- les apps infra : `argocd/cilium.yaml`, `argocd/cilium-gateway.yaml`, `argocd/cloudflare-tunnel-controller.yaml`.

Rien d'autre à installer à la main : le monitoring (VictoriaMetrics, DCGM…) est déployé par `root`.

## Nettoyage après désactivation de dex et des notifications

`infra/argocd/values.yaml` désactive dex et argocd-notifications, mais l'Application `argocd` est en `prune: false` :
leurs ressources restent en place (OutOfSync « à supprimer »). Une seule fois sur le cluster existant (inutile après
une réinstallation) :

```bash
kubectl -n argocd delete deploy/argocd-dex-server deploy/argocd-notifications-controller \
  svc/argocd-dex-server sa/argocd-dex-server sa/argocd-notifications-controller \
  role/argocd-dex-server role/argocd-notifications-controller \
  rolebinding/argocd-dex-server rolebinding/argocd-notifications-controller \
  networkpolicy/argocd-dex-server networkpolicy/argocd-notifications-controller \
  cm/argocd-notifications-cm secret/argocd-notifications-secret --ignore-not-found
kubectl delete clusterrole/argocd-notifications-controller clusterrolebinding/argocd-notifications-controller --ignore-not-found
```
