#!/usr/bin/env python3
"""Ajoute chiffrement etcd + audit à kube-apiserver (manifest statique ET kubeadm-config).

Procédure complète : README.md, section « Chiffrement etcd + audit de l'API server ».
Usage : patch-apiserver.py <kube-apiserver.yaml> <kubeadm-config-cm.yaml> <outdir>
Écrit <outdir>/kube-apiserver.yaml et <outdir>/kubeadm-config.yaml sans toucher aux entrées.
Idempotent : relancer ne duplique rien.
"""
import sys
import yaml

ARGS = {
    "encryption-provider-config": "/etc/kubernetes/enc/encryption-config.yaml",
    "audit-policy-file": "/etc/kubernetes/audit-policy.yaml",
    "audit-log-path": "/var/log/kubernetes/audit/audit.log",
    "audit-log-maxage": "7",
    "audit-log-maxbackup": "3",
    "audit-log-maxsize": "50",
}
VOLUMES = [
    # name, hostPath, mountPath, readOnly, pathType
    ("enc-config", "/etc/kubernetes/enc", "/etc/kubernetes/enc", True, "DirectoryOrCreate"),
    ("audit-policy", "/etc/kubernetes/audit-policy.yaml", "/etc/kubernetes/audit-policy.yaml", True, "File"),
    ("audit-log", "/var/log/kubernetes/audit", "/var/log/kubernetes/audit", False, "DirectoryOrCreate"),
]


def patch_manifest(pod):
    c = next(c for c in pod["spec"]["containers"] if c["name"] == "kube-apiserver")
    cmd = c["command"]
    for k, v in ARGS.items():
        cmd[:] = [a for a in cmd if not a.startswith(f"--{k}=")]
        cmd.append(f"--{k}={v}")
    mounts = c.setdefault("volumeMounts", [])
    vols = pod["spec"].setdefault("volumes", [])
    for name, host, mnt, ro, ptype in VOLUMES:
        mounts[:] = [m for m in mounts if m["name"] != name]
        vols[:] = [v for v in vols if v["name"] != name]
        m = {"mountPath": mnt, "name": name}
        if ro:
            m["readOnly"] = True
        mounts.append(m)
        vols.append({"hostPath": {"path": host, "type": ptype}, "name": name})
    return pod


def patch_cluster_config(cc):
    api = cc.get("apiServer") or {}
    v1beta4 = cc.get("apiVersion", "").endswith("v1beta4")
    extra = api.get("extraArgs") or ([] if v1beta4 else {})
    if v1beta4:
        extra = [a for a in extra if a["name"] not in ARGS]
        extra += [{"name": k, "value": v} for k, v in ARGS.items()]
    else:
        extra.update(ARGS)
    api["extraArgs"] = extra
    ev = [v for v in (api.get("extraVolumes") or []) if v["name"] not in {n for n, *_ in VOLUMES}]
    for name, host, mnt, ro, ptype in VOLUMES:
        ev.append({"name": name, "hostPath": host, "mountPath": mnt, "readOnly": ro, "pathType": ptype})
    api["extraVolumes"] = ev
    cc["apiServer"] = api
    return cc


def main():
    manifest, cm_path, outdir = sys.argv[1:4]
    pod = yaml.safe_load(open(manifest))
    with open(f"{outdir}/kube-apiserver.yaml", "w") as f:
        yaml.safe_dump(patch_manifest(pod), f, sort_keys=False)

    cm = yaml.safe_load(open(cm_path))
    for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields", "annotations"):
        cm["metadata"].pop(k, None)
    cc = yaml.safe_load(cm["data"]["ClusterConfiguration"])
    cm["data"]["ClusterConfiguration"] = yaml.safe_dump(patch_cluster_config(cc), sort_keys=False)
    with open(f"{outdir}/kubeadm-config.yaml", "w") as f:
        yaml.safe_dump(cm, f, sort_keys=False)
    print("OK :", f"{outdir}/kube-apiserver.yaml", f"{outdir}/kubeadm-config.yaml")


if __name__ == "__main__":
    main()
