# PowerFlex SDC on Flatcar

Build the Dell PowerFlex SDC kernel module for Flatcar and load it through a Kubernetes init container. A DaemonSet restores the module after a node reboot without modifying Flatcar's read-only `/usr` filesystem.

This is a **lab integration**, not a Dell-certified Flatcar configuration. Module loading, host-side `drv_cfg`, and automatic loading after reboot have been tested. Backend connectivity and Kubernetes volume I/O have not been tested.

## Supported build target

These scripts are pinned to one tested combination. They are not a generic installer for other releases.

| Component | Version |
| --- | --- |
| Flatcar | 4757.2.0, amd64 |
| Kernel | 6.12.109-flatcar |
| PowerFlex SDC | 5.0.0.941, from the pinned Dell SDC 5.0 image |
| Build environment | Flatcar developer container 4757.2.0, GCC 15.2.1 |
| Kubernetes used for validation | 1.36.4 |

**Kernel IBT must be disabled for this build.** Dell's precompiled objects produce IBT incompatibility warnings. Disabling IBT reduces kernel protection; use a dedicated test node. The init container refuses to run without `ibt=off`. The resulting proprietary, unsigned module taints the kernel.

## Prerequisites

On your local Linux machine:

- SSH, curl, tar, bzip2, GNU coreutils, `debugfs`, GnuPG, `modinfo`, Python 3, and Bubblewrap (`bwrap`).
- Unprivileged user namespaces enabled for Bubblewrap.
- About 15 GB of free disk space for the build environment and temporary files.
- Network access to Flatcar downloads and the Dell image registry.

On the target node:

- The exact Flatcar and kernel versions listed above.
- SSH access with passwordless sudo and Docker available for extracting the builder.
- Kubernetes access allowing a privileged init container and hostPath mounts.
- Kernel module loading permitted, without enforced module signatures or lockdown preventing the unsigned module.

Install the Python dependency and choose your target:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt

export SDC_NODE=core@YOUR_NODE_IP
export KUBE_NODE=YOUR_KUBERNETES_NODE_NAME
```

The SSH commands use `-F /dev/null` to ignore local SSH configuration. Remove that option from the scripts and commands if your connection requires a configured jump host or other SSH settings.

## 1. Build the module

```bash
./scripts/build-scini.sh
```

The script extracts Dell's builder from the pinned SDC image, copies the target node's prepared kernel build tree, verifies the matching Flatcar developer image's GPG signature, and runs the builder with the matching compiler in Bubblewrap.

The result is:

```text
.work/artifacts/4757.2.0/6.12.109-flatcar/scini.ko
```

Review `.work/logs/scini-build.log`. The build produces warnings involving Dell's precompiled objects; successful compilation does not establish production compatibility. No Dell source patches or forced compilation are used. The prepared Flatcar headers already contain `Module.symvers`, so another `modules_prepare` step is unnecessary for this target.

## 2. Disable IBT on the test node

Connect to the node:

```bash
ssh -F /dev/null "$SDC_NODE"
```

Back up the boot configuration and append the parameter once:

```bash
sudo cp -an /usr/share/oem/grub.cfg /usr/share/oem/grub.cfg.before-powerflex
if ! grep -q 'ibt=off' /usr/share/oem/grub.cfg; then
  cat <<'GRUB' | sudo tee -a /usr/share/oem/grub.cfg

# PowerFlex SDC lab: proprietary objects are not IBT-compatible.
set linux_append="$linux_append ibt=off"
GRUB
fi
sudo reboot
```

After the node returns, confirm that `/proc/cmdline` contains `ibt=off`:

```bash
ssh -F /dev/null "$SDC_NODE" 'cat /proc/cmdline'
```

## 3. Upload the module

Run locally:

```bash
ssh -F /dev/null "$SDC_NODE" \
  'sudo mkdir -p /var/emc-scaleio/driver_cache/USUPPORTED/5.0.0.941/6.12.109-flatcar'
ssh -F /dev/null "$SDC_NODE" \
  'sudo tee /var/emc-scaleio/driver_cache/USUPPORTED/5.0.0.941/6.12.109-flatcar/scini.ko >/dev/null' \
  < .work/artifacts/4757.2.0/6.12.109-flatcar/scini.ko
```

`USUPPORTED` is the actual directory name used by Dell's OS detection. The loader finds the locally compiled module there; no RHEL identity spoofing is required.

## 4. Generate and install the DaemonSet

```bash
mkdir -p dist
./scripts/render-manifest.py --node "$KUBE_NODE" > dist/sdc.yaml
```

The renderer embeds the checksum of your built module and the init script into a ConfigMap. It defaults to the namespace `powerflex-sdc` and an empty MDM list, which is suitable for checking installation without a backend.

For a real backend, generate the manifest with its MDM addresses instead:

```bash
./scripts/render-manifest.py --node "$KUBE_NODE" \
  --mdm '192.0.2.10,192.0.2.11' > dist/sdc.yaml
```

Replace the example addresses and check that SDC 5.0.0.941 is compatible with your PowerFlex system. Backend authentication and SDC approval may require additional configuration.

Review `dist/sdc.yaml`, then apply it with a kubeconfig that can manage the cluster:

```bash
kubectl apply -f dist/sdc.yaml
kubectl -n powerflex-sdc wait --for=condition=Ready \
  pod -l app=flatcar-sdc --timeout=180s
```

If kubectl is only available on the KubeOne node, apply over SSH instead:

```bash
ssh -F /dev/null "$SDC_NODE" \
  'sudo /opt/bin/kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f -' \
  < dist/sdc.yaml
```

The privileged init container loads the module and installs `drv_cfg`, its missing libraries, and a udev rule. The long-running health container is unprivileged. No host RPM installation, system extension, or separate `scini.service` is required.

## 5. Verify

On the node:

```bash
lsmod | grep scini
sudo /opt/emc/scaleio/sdc/bin/drv_cfg --query_version
sudo /opt/emc/scaleio/sdc/bin/drv_cfg --query_guid
sudo /opt/emc/scaleio/sdc/bin/drv_cfg --query_mdm
```

Without a backend, `Retrieved 0 mdm(s)` is expected. DaemonSet readiness only checks whether `scini` is loaded; it does not prove a working storage connection.

Inspect Kubernetes status and init logs:

```bash
kubectl -n powerflex-sdc get daemonset flatcar-sdc
kubectl -n powerflex-sdc logs -l app=flatcar-sdc -c sdc
```

Reboot the test node and repeat these checks. The DaemonSet should reload the module and preserve the SDC GUID, which Dell derives from the node name.

## Optional: integrate with the PowerFlex CSI Helm chart

`values.flatcar-sdc.yaml` and `scripts/helm-flatcar-post-renderer.py` adapt the **csi-vxflexos 2.16.0** chart. This path has been rendered and inspected, but not validated against a PowerFlex backend.

```bash
helm repo add dell https://dell.github.io/helm-charts
helm repo update
helm template powerflex dell/csi-vxflexos --version 2.16.0 \
  --namespace powerflex -f values.flatcar-sdc.yaml \
  --post-renderer ./scripts/helm-flatcar-post-renderer.py > dist/csi.yaml
```

Keep the Python virtual environment active. The post-renderer uses the locally built module's checksum; set `SDC_MODULE` to use a different local artifact path.

The post-renderer removes the immutable legacy host `/bin/emc/scaleio` mount, adds the host kernel-module mount, and uses the same init script as the standalone DaemonSet. SDC remains enabled.

Before installing a real CSI release, follow Dell's installer requirements for backend secrets, service accounts, RBAC, and compatible versions. The raw chart does not create every prerequisite. Replace the standalone SDC DaemonSet with the CSI-managed init container in a planned maintenance window; do not let both independently manage the module. Validate MDM connectivity, PVC provisioning, mounting, and read/write I/O afterward.

## Updates and removal

For each Flatcar kernel update, build and validate a new module first, then update the pinned versions, cache location, init checks, and rendered manifest before rebooting into that kernel. Automatic Flatcar updates are not disabled by these scripts. An unmatched kernel makes the init container fail.

The DaemonSet uses `OnDelete` updates. After changing its configuration, recreate the affected Pod during a storage maintenance window. The Dell loader can reload an unused module.

To remove the deployment, stop workloads using PowerFlex, unmount their volumes, and run:

```bash
kubectl -n powerflex-sdc delete daemonset flatcar-sdc
kubectl -n powerflex-sdc delete configmap flatcar-sdc-init
```

Deleting a Pod does not unload the module or remove host files. Once no volumes use it, unload with `sudo rmmod scini`. Remove the installation's files under `/opt/emc/scaleio/sdc/bin`, `/etc/udev/rules.d/20-scini.rules`, and its kernel cache directory only after checking that nothing else uses them. Remove the PowerFlex `ibt=off` addition from `/usr/share/oem/grub.cfg` and reboot to restore IBT. Do not overwrite unrelated boot configuration changes when restoring the backup.

## Repository contents

- `scripts/build-scini.sh` — retrieve the builder and compile the module.
- `scripts/render-manifest.py` — generate the standalone deployment.
- `scripts/flatcar-sdc-init.sh` — container-side installation logic.
- `scripts/helm-flatcar-post-renderer.py` — optional CSI chart adaptation.
- `templates/sdc-daemonset.yaml` — deployment template; render it before applying.
- `values.flatcar-sdc.yaml` — pinned CSI chart overrides.

Proprietary Dell binaries, extracted sources, Flatcar images, build outputs, and local investigation notes are excluded from Git. Dell software remains subject to its own license terms.

## References

- [Dell: on-demand SDC compilation](https://www.dell.com/support/kbdoc/en-us/000224134/how-to-on-demand-compilation-of-the-powerflex-sdc-driver)
- [Flatcar: building external kernel modules](https://www.flatcar.org/docs/latest/devguide/kernel-modules/)
- [Flatcar: kernel boot parameters](https://www.flatcar.org/docs/latest/setup/customization/other-settings/)
