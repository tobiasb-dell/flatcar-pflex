#!/usr/bin/env python3
"""SDC init integration for csi-vxflexos 2.16.0; requires PyYAML.

Use instead of the standalone SDC DaemonSet once a real backend is available.
Keep node.sdc.enabled=true: disabling it switches the CSI data path away from SDC.
"""
import sys
import os
import yaml
from sdc_manifest import DEFAULT_MODULE, init_configmap

docs = list(yaml.safe_load_all(sys.stdin))
patched = 0
for obj in docs:
    if not obj or obj.get("kind") != "DaemonSet":
        continue
    spec = obj["spec"]["template"]["spec"]
    init = next((c for c in spec.get("initContainers", []) if c["name"] == "sdc"), None)
    if init is None:
        continue
    patched += 1
    # The legacy host /bin path is immutable; the supported /opt mount remains.
    spec["volumes"] = [v for v in spec["volumes"] if v["name"] != "scaleio-path-bin"]
    for c in spec.get("containers", []) + spec.get("initContainers", []):
        c["volumeMounts"] = [v for v in c.get("volumeMounts", []) if v["name"] != "scaleio-path-bin"]
    for v in spec["volumes"]:
        if v["name"] == "host-opt-emc-path":
            v["hostPath"]["type"] = "DirectoryOrCreate"
    spec["volumes"] += [
        {"name": "flatcar-init", "configMap": {"name": "flatcar-sdc-init"}},
        {"name": "flatcar-kernel-modules", "hostPath": {"path": "/usr/lib/modules", "type": "Directory"}},
    ]
    init["command"] = ["/bin/bash", "/flatcar/install.sh"]
    init["volumeMounts"] += [
        {"name": "flatcar-init", "mountPath": "/flatcar", "readOnly": True},
        {"name": "flatcar-kernel-modules", "mountPath": "/lib/modules", "readOnly": True},
    ]
    docs.append(init_configmap(obj["metadata"]["namespace"], os.environ.get("SDC_MODULE", DEFAULT_MODULE)))
if patched != 1:
    sys.exit(f"Expected exactly one SDC DaemonSet from chart 2.16.0; found {patched}")
yaml.safe_dump_all(docs, sys.stdout, sort_keys=False)
