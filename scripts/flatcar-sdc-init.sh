#!/bin/bash
# Runs INSIDE the pinned Dell SDC 5.0 image. Host mounts match the manifest.
set -euo pipefail
kernel=6.12.109-flatcar
version=5.0.0.941
expected_sha=MODULE_SHA256
test "$(uname -r)" = "$kernel"
grep -qx 'VERSION_ID="4757.2.0"' /host-os-release
# This specific proprietary build is not compatible with active kernel IBT.
grep -Eq '(^| )ibt=off( |$)' /proc/cmdline
module="/storage/driver_cache/USUPPORTED/$version/$kernel/scini.ko"
echo "$expected_sha  $module" | sha256sum --check --status

# Original Dell loader finds the exact locally built module; no OS spoofing.
/files/scripts/init.sh
grep -qw scini /proc/modules
/bin/emc/scaleio/drv_cfg --query_guid

# Keep the Flatcar /usr immutable; supply missing libraries next to the tool.
mkdir -p /host_drv_cfg_path/lib
cp -L /lib64/libnuma.so.1 /lib64/libaio.so.1 /host_drv_cfg_path/lib/
cp /bin/emc/scaleio/drv_cfg /host_drv_cfg_path/drv_cfg.real
chmod 0755 /host_drv_cfg_path/drv_cfg.real
cat > /host_drv_cfg_path/drv_cfg <<'WRAPPER'
#!/bin/sh
tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LD_LIBRARY_PATH="$tool_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$tool_dir/drv_cfg.real" "$@"
WRAPPER
chmod 0755 /host_drv_cfg_path/drv_cfg
echo 'Flatcar SDC installation and userspace setup complete.'
