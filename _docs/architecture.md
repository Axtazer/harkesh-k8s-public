[← Sommaire](README.md)


# Architecture réseau

Un seul chemin d'entrée : le Cloudflare Tunnel, qui aboutit directement sur les Services K8s.

```
Internet
   ↓
Cloudflare Edge (TLS, Cloudflare Access)
   ↓
cloudflared (connecteur géré par cloudflare-tunnel-ingress-controller)
   ↓  Ingress cloudflare-tunnel → Service   (CF-Connecting-IP / X-Forwarded-For)
Services K8s
```

- **Cloudflare Tunnel** : géré en GitOps via `ingressClassName: cloudflare-tunnel` (un `routes.yaml` par app).
  Cloudflare Access (dashboard Zero Trust, pas de manifest K8s) protège tout ce chemin.
- **Cilium Gateway API** (`shared-gateway` @ `192.168.1.203`, kube-system) : conservé mais **sans aucune
  HTTPRoute**, et **sans annonce L2** (voir ci-dessous) — l'IP est allouée mais injoignable depuis le LAN.
  L'accès LAN direct n'est plus utilisé et contournait Cloudflare Access (HTTP clair, sans
  auth). Les namespaces gardent le label `shared-gateway-access: "true"` pour pouvoir rebrancher une
  route rapidement.
- **L2 IPAM** : `CiliumLoadBalancerIPPool` seul → IP `192.168.1.203` allouée au `shared-gateway`.
  La `CiliumL2AnnouncementPolicy` a été **retirée** : `192.168.1.203` est réservée côté LAN, l'annoncer
  en ARP créerait un conflit d'adresse. Personne sur le réseau ne route donc vers cette IP.
- **NetworkPolicies** : deny-all (ingress + egress) + allow ciblés dans tous les namespaces applicatifs
  (`authentik`, `axtazer-me`, `bots`, `flo-pro`, `french-breakfast`, `livekit`, `matrix`, `media`, `monitoring`,
  `n8n`, `nextcloud`, `ntfy`, `pelican`, `root-panel`, `shlink`, `wings`). Les flux autorisés sont documentés en tête de chaque
  `networkpolicy.yaml`. Règles communes : entrée uniquement depuis le connecteur cloudflared, sortie Internet
  sans les plages privées (`10/8`, `172.16/12`, `192.168/16`), DNS vers `kube-system`. L'hôte et l'API server ne
  sont pas joignables par `ipBlock` sous Cilium → `CiliumNetworkPolicy` `toEntities: [host | kube-apiserver]`
  (Panel → Wings, composants de `monitoring`). Non couverts : pods `hostNetwork` (Wings, node-exporter) et
  namespaces système (`kube-system`, `argocd`, `1password`, `cloudflare-tunnel-ingress-controller`).
- **Hubble** (observabilité réseau Cilium) : la CLI n'est pas installée sur l'hôte, le binaire est dans l'agent.
  Voir ce qu'une NetworkPolicy bloque : `kubectl exec -n kube-system ds/cilium -- hubble observe -n <namespace> --verdict DROPPED --follow`
  (le message `EVENTS LOST: HUBBLE_RING_BUFFER` signale un tampon dépassé, pas un flux bloqué).
  Métriques : `hubble_drop_total` (paquets refusés par namespace/workload source et destination, raison —
  `POLICY_DENIED` = NetworkPolicy), scrapées par vmagent (`hubble.metrics` dans `infra/cilium/values.yaml`).
  Interface web : `kubectl port-forward -n kube-system svc/hubble-ui 12000:80` → `http://localhost:12000`.

## Accès de secours (si Cloudflare est indisponible)

Depuis le nœud (SSH), un port-forward suffit, sans rien exposer :

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:80        # http://localhost:8080
kubectl port-forward -n nextcloud svc/nextcloud 8081:80
```

Pour un accès LAN durable à une app, ajouter une `HTTPRoute` rattachée au `shared-gateway` dans son
`routes.yaml` (le namespace doit porter le label `shared-gateway-access: "true"`) :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mon-app
  namespace: mon-namespace
spec:
  parentRefs:
    - name: shared-gateway
      namespace: kube-system
  hostnames: [mon-app.mydomain2.fr]
  rules:
    - backendRefs:
        - name: mon-app
          port: 80
```
Puis faire pointer le nom DNS (ou `/etc/hosts`) vers l'IP du Gateway.

> ⚠️ **Ce chemin ne fonctionne pas en l'état** : il n'y a plus de `CiliumL2AnnouncementPolicy`, donc
> `192.168.1.203` n'est annoncée en ARP par personne et reste injoignable depuis le LAN. Pour le
> réactiver : allouer une IP **libre** au pool dans `infra/cilium/lb-pool.yaml` (la `.203` est réservée
> côté réseau), repasser `l2announcements.enabled: true` dans `infra/cilium/values.yaml` (puis
> `kubectl -n kube-system rollout restart ds/cilium`), et recréer la policy avec `interfaces: [eno1]`.

Attention aussi : ce chemin n'a pas Cloudflare Access devant lui — si la NetworkPolicy du namespace
n'autorise que `cloudflared`, il faut aussi autoriser l'ingress depuis le Gateway (Envoy Cilium,
`hostNetwork`).
