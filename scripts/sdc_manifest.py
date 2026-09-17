"""Shared manifest helpers; proprietary module contents are never embedded."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MODULE = ROOT / ".work/artifacts/4757.2.0/6.12.109-flatcar/scini.ko"


def init_configmap(namespace, module=DEFAULT_MODULE):
    digest = hashlib.sha256(Path(module).read_bytes()).hexdigest()
    script = (ROOT / "scripts/flatcar-sdc-init.sh").read_text()
    script = script.replace("expected_sha=MODULE_SHA256", f"expected_sha={digest}")
    return {
        "apiVersion": "v1", "kind": "ConfigMap",
        "metadata": {"name": "flatcar-sdc-init", "namespace": namespace},
        "data": {"install.sh": script},
    }
