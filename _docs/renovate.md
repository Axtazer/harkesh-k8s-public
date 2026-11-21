[← Sommaire](README.md)


# Renovate

Les images Docker sont suivies et mises à jour automatiquement via Renovate (config dans `renovate.json`).

| Image | Stratégie |
|---|---|
| `nextcloud` + `mariadb` + `redis` | Manuel — review obligatoire |
| `ghcr.io/pelican/*` | Automerge digest/patch/minor |
| `cloudflare-tunnel-ingress-controller` (Helm, manager `argocd`) | Automerge patch/minor |
| Charts Helm des Applications ArgoCD (`argo-cd`, `cilium`, `victoria-metrics-k8s-stack`, `dcgm-exporter`, `nvidia-device-plugin`, `metrics-server`, `prometheus-operator-crds`, `victoria-logs-single`, `victoria-logs-collector`, `tetragon`, chart `n8n`, chart `connect` de 1Password) | Manuel — review obligatoire (manager `argocd` sur `argocd/*.yaml`) |
| CRDs Gateway API (`kubernetes-sigs/gateway-api`, `infra/cilium/gateway-api-crds.yaml`) | Manuel — doit rester dans la matrice de compatibilité de Cilium |
| `gcr.io/cadvisor/cadvisor` | Automerge digest/patch/minor |
| `ghcr.io/axtazer/alchimie-creatures` | Automerge digest (tag `main`) |
| `ghcr.io/axtazer/axtazer-me` | Automerge digest |
| `ghcr.io/axtazer/root-panel` | Automerge digest (tag `latest`) + workflow `update-image` |
| `ghcr.io/axtazer/axtazia` | Automerge digest (tag `latest`) + workflow `update-image` |
| `ghcr.io/axtazer/flo-pro` | Automerge digest (lookup limité — image GHCR privée, cf. workflow `update-image`) |
| `ghcr.io/axtazer/french-breakfast` | Automerge digest (tag `main`) |
| `ghcr.io/shlinkio/shlink` + `shlink-web-client` | Automerge digest/patch/minor |
| `ghcr.io/goauthentik/server` | Automerge digest/patch/minor — major manuel (migrations BDD) |
| `binwiederhier/ntfy` | Automerge digest/patch/minor — major manuel |
| `matrixdotorg/synapse` | Manuel — review obligatoire (jamais d'automerge) |
| `gnuxie/draupnir` | Manuel — review obligatoire (jamais d'automerge, compte avec droits de modération/admin) |
| `dock.mau.dev/maubot/maubot` | Manuel — review obligatoire (jamais d'automerge, compte Matrix du bot + migrations de la base maubot/plugins) |
| `livekit/livekit-server` + `ghcr.io/element-hq/lk-jwt-service` + `lscr.io/linuxserver/wireguard` (sidecar) | Manuel — review obligatoire (jamais d'automerge, relais réseau critique) |
| `postgres` (shlink, n8n, authentik) | Automerge digest — major bloqué (migrations irréversibles) |
| `n8nio/n8n` | Automerge digest/patch/minor — major manuel |
| `busybox` + `nginx` (well-known Matrix) | Automerge digest/patch/minor |
| `yannh/kubeconform` + `mikefarah/yq` (CI) | Automerge digest/patch/minor |
| `jellyfin/jellyfin` | Automerge digest/patch — minor/major manuel |
| `lscr.io/linuxserver/*` + `ghcr.io/qdm12/gluetun` | Automerge digest/patch/minor |
| `ghcr.io/seerr-team/seerr` | Automerge digest/patch/minor — versioning semver forcé (registre à tags roulants) |
| Toutes les majors | Manuel — review obligatoire |
