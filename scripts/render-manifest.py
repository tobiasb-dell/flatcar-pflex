#!/usr/bin/env python3
"""Render a single-node SDC installation with its actual module checksum."""
import argparse
from pathlib import Path
import sys
import yaml
from sdc_manifest import DEFAULT_MODULE, ROOT, init_configmap

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--node", required=True, help="Kubernetes hostname label value")
parser.add_argument("--namespace", default="powerflex-sdc")
parser.add_argument("--mdm", default="", help="Comma-separated MDM IPs; empty for a backend-free test")
parser.add_argument("--module", type=Path, default=DEFAULT_MODULE)
args = parser.parse_args()
docs = list(yaml.safe_load_all((ROOT / "templates/sdc-daemonset.yaml").read_text()))
for obj in docs:
    if obj["kind"] == "Namespace":
        obj["metadata"]["name"] = args.namespace
    else:
        obj["metadata"]["namespace"] = args.namespace
        spec = obj["spec"]["template"]["spec"]
        spec["nodeSelector"]["kubernetes.io/hostname"] = args.node
        for env in spec["initContainers"][0]["env"]:
            if env["name"] == "MDM":
                env["value"] = args.mdm
try:
    docs.insert(1, init_configmap(args.namespace, args.module))
except OSError as exc:
    parser.error(f"Cannot read the built module: {exc}")
yaml.safe_dump_all(docs, sys.stdout, sort_keys=False)
