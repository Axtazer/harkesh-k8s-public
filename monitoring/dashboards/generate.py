#!/usr/bin/env python3
"""Génère les ConfigMaps des dashboards Grafana (monitoring/grafana-dashboards-*.yaml).

Source de vérité = la liste DASHBOARDS ci-dessous :
  - dashboards grafana.com épinglés par (id, révision) : téléchargés puis normalisés ;
  - dashboards maison : JSON lisible dans ce dossier (monitoring/dashboards/<nom>.json).

Chaque ConfigMap porte le label grafana_dashboard: "1" (lu par le sidecar Grafana) et l'annotation
grafana_folder (dossier Grafana, cf. sidecar.dashboards.folderAnnotation dans
argocd/victoria-metrics-k8s-stack.yaml). Le JSON est minifié, et les ConfigMaps sont appliquées en
Server-Side Apply (annotation ArgoCD) : Node Exporter Full dépasse la limite de 256 Ko de
l'annotation last-applied du client-side apply.

Usage (depuis la racine du dépôt) :
  python3 monitoring/dashboards/generate.py          # régénère les fichiers
  python3 monitoring/dashboards/generate.py --check  # échoue si les fichiers ne sont pas à jour

Monter de version un dashboard grafana.com = changer sa révision ici, relancer, committer.
Révisions disponibles : https://grafana.com/api/dashboards/<id>/revisions
Ce dossier n'est pas lu par ArgoCD (l'app monitoring n'est pas récursive).
"""
import glob
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.dirname(HERE)  # monitoring/

# (nom de la ConfigMap sans préfixe, dossier Grafana, source)
# source = ("gnet", id, révision) ou ("file", "<nom>.json")
DASHBOARDS = [
    # Serveur (hôte, node-exporter)
    ("serveur-harkesh", "Serveur", ("file", "serveur-harkesh.json")),
    ("node-exporter-full", "Serveur", ("gnet", 1860, 45)),
    # Kubernetes (métriques brutes, aucune recording rule : vmalert est désactivé)
    ("kubernetes-harkesh", "Kubernetes", ("file", "kubernetes-harkesh.json")),
    ("k8s-views-global", "Kubernetes", ("gnet", 15757, 43)),
    ("k8s-views-namespaces", "Kubernetes", ("gnet", 15758, 46)),
    ("k8s-views-nodes", "Kubernetes", ("gnet", 15759, 40)),
    ("k8s-views-pods", "Kubernetes", ("gnet", 15760, 41)),
    ("k8s-system-api-server", "Kubernetes", ("gnet", 15761, 21)),
    ("k8s-system-coredns", "Kubernetes", ("gnet", 15762, 22)),
    # GPU (dcgm-exporter)
    ("nvidia-dcgm", "GPU", ("gnet", 12239, 2)),
    # Serveurs de jeux (cAdvisor Docker : conteneurs Pelican/Wings)
    ("jeux-pelican", "Jeux", ("file", "jeux-pelican.json")),
    # Monitoring lui-même
    ("victoriametrics-single", "Monitoring", ("gnet", 10229, 59)),
    ("victoriametrics-vmagent", "Monitoring", ("gnet", 12683, 42)),
    ("victoriametrics-operator", "Monitoring", ("gnet", 17869, 10)),
    ("victorialogs-single", "Monitoring", ("gnet", 22084, 12)),
    # Sécurité : audit API + Tetragon (VictoriaLogs), paquets refusés (Hubble)
    ("securite", "Sécurité", ("file", "securite.json")),
    # Cloudflare (datasource Infinity)
    ("cloudflare-dns-analytics", "Cloudflare", ("file", "cloudflare-dns-analytics.json")),
]

DEFAULT_DS_UID = "prometheus"  # datasource VictoriaMetrics (defaultDatasources du chart)


def fetch_gnet(gid, rev):
    url = f"https://grafana.com/api/dashboards/{gid}/revisions/{rev}/download"
    try:
        with urllib.request.urlopen(url, timeout=60) as r:  # noqa: S310 (URL fixe)
            return r.read().decode()
    except urllib.error.URLError as e:
        sys.exit(f"téléchargement impossible de {url} : {e}")


def normalize(raw):
    """Remplace les entrées d'import (${DS_X}) par la datasource par défaut et nettoie l'export."""
    d = json.loads(raw)
    var_names = {v.get("name") for v in d.get("templating", {}).get("list", [])}
    for inp in d.get("__inputs", []):
        if inp.get("type") != "datasource" or inp["name"] in var_names:
            continue  # une variable du dashboard porte déjà ce nom : elle se résout seule
        if inp.get("pluginId") != "prometheus":
            sys.exit(f"entrée {inp['name']} de type {inp.get('pluginId')} non gérée")
        raw = raw.replace("${" + inp["name"] + "}", DEFAULT_DS_UID)
    d = json.loads(raw)
    for k in ("__inputs", "__requires", "__elements"):
        d.pop(k, None)
    d["id"] = None
    # Variables de type datasource : laisser Grafana choisir la datasource par défaut
    for v in d.get("templating", {}).get("list", []):
        if v.get("type") == "datasource":
            v["current"] = {}
    return d


def load(source):
    if source[0] == "gnet":
        return normalize(fetch_gnet(source[1], source[2]))
    with open(os.path.join(HERE, source[1]), encoding="utf-8") as f:
        return json.load(f)


def slug(folder):
    ascii_name = unicodedata.normalize("NFKD", folder).encode("ascii", "ignore").decode()  # Sécurité -> Securite
    return re.sub(r"[^a-z0-9]+", "-", ascii_name.lower()).strip("-")


def render():
    files = {}
    uids = {}
    for name, folder, source in DASHBOARDS:
        d = load(source)
        uid = d.get("uid")
        if not uid:  # sans uid fixe, Grafana en tire un au hasard à chaque redémarrage (liens cassés)
            sys.exit(f"{name} : pas d'uid")
        if uid in uids:
            sys.exit(f"uid {uid} en double : {uids[uid]} et {name}")
        uids[uid] = name
        origin = (f"grafana.com {source[1]} révision {source[2]}" if source[0] == "gnet"
                  else f"monitoring/dashboards/{source[1]}")
        body = json.dumps(d, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        # Sauts de ligne Unicode : YAML les lirait comme des fins de ligne dans le bloc littéral
        for ch in ("\u2028", "\u2029", "\x85"):
            body = body.replace(ch, "\\u%04x" % ord(ch))
        doc = (
            "---\n"
            f"# {d.get('title')} — {origin}\n"
            "apiVersion: v1\n"
            "kind: ConfigMap\n"
            "metadata:\n"
            f"  name: grafana-dashboard-{name}\n"
            "  namespace: monitoring\n"
            "  labels:\n"
            '    grafana_dashboard: "1"\n'
            "  annotations:\n"
            f"    grafana_folder: {json.dumps(folder, ensure_ascii=False)}\n"
            "    argocd.argoproj.io/sync-options: ServerSideApply=true\n"
            "data:\n"
            f"  {name}.json: |-\n"
            f"    {body}\n"
        )
        path = os.path.join(OUT_DIR, f"grafana-dashboards-{slug(folder)}.yaml")
        files.setdefault(path, [
            "# Généré par monitoring/dashboards/generate.py — ne pas éditer à la main.\n"
        ]).append(doc)
    return {p: "".join(parts) for p, parts in files.items()}


def main():
    check = "--check" in sys.argv
    files = render()
    existing = set(glob.glob(os.path.join(OUT_DIR, "grafana-dashboards-*.yaml")))
    stale = []
    for path, content in files.items():
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if current != content:
            stale.append(path)
            if not check:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(content)
    for path in existing - set(files):
        stale.append(path)
        if not check:
            os.remove(path)
    for path in stale:
        print(("à régénérer : " if check else "écrit : ") + os.path.relpath(path))
    if check and stale:
        sys.exit(1)


if __name__ == "__main__":
    main()
