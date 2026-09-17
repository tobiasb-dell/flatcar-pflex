#!/usr/bin/env bash
# Local Linux build. Needs: ssh, curl, tar, bzip2, debugfs, gpg, bwrap, python3.
# Does not change the target node; Docker there is used only to extract Dell's bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
node=${SDC_NODE:?Set SDC_NODE to the SSH destination, e.g. core@your-node}
work=$PWD/.work
image=quay.io/dell/storage/powerflex/sdc:5.0@sha256:1436844390ea95507bf0a24c68a300a355f010a90ed654a42a1f091482b6a0fc
url=https://stable.release.flatcar-linux.net/amd64-usr/4757.2.0/flatcar_developer_container.bin.bz2
mkdir -p "$work/flatcar" "$work/kernel-build" "$work/scini-builder" "$work/logs"
ssh -F /dev/null "$node" 'test "$(uname -r)" = 6.12.109-flatcar && test "$(uname -m)" = x86_64 && grep -qx '\''VERSION_ID="4757.2.0"'\'' /etc/os-release'
ssh -F /dev/null "$node" 'sudo tar -C /usr/lib/modules/6.12.109-flatcar/build -czf - .' > "$work/flatcar/kernel-build.tgz"
ssh -F /dev/null "$node" 'zcat /proc/config.gz' > "$work/flatcar/kernel.config"
tar -xzf "$work/flatcar/kernel-build.tgz" -C "$work/kernel-build"
ssh -F /dev/null "$node" "sudo docker run --rm --entrypoint /bin/cat $image /bin/emc/scaleio/scini_sync/driver_cache/RHEL9/5.0.0.941/Dell-PowerFlex-scini_builder-5.0.0.941.x86_64.tgz" > "$work/scini-builder.tgz"
tar -xzf "$work/scini-builder.tgz" -C "$work/scini-builder"
# Never mistake a previous build artifact for a successful new compilation.
rm -f "$work/scini-builder/ini/scini.ko" "$work/scini-builder/ini/linux/api/scini.ko"

if [ ! -s "$work/flatcar/developer.bin.bz2" ]; then
  curl --fail --location "$url" -o "$work/flatcar/developer.bin.bz2.part"
  mv "$work/flatcar/developer.bin.bz2.part" "$work/flatcar/developer.bin.bz2"
fi
curl --fail --location "$url.sig" -o "$work/flatcar/developer.bin.bz2.sig"
curl --fail --location https://www.flatcar.org/security/image-signing-key/Flatcar_Image_Signing_Key.asc -o "$work/flatcar/signing-key.asc"
mkdir -m 700 -p "$work/gnupg"
gpg --homedir "$work/gnupg" --batch --no-autostart --import "$work/flatcar/signing-key.asc"
gpg --homedir "$work/gnupg" --batch --no-autostart --verify "$work/flatcar/developer.bin.bz2.sig" "$work/flatcar/developer.bin.bz2"

if [ ! -f "$work/devroot/.extraction-complete" ]; then
  bzip2 -dc "$work/flatcar/developer.bin.bz2" | cp --sparse=always /dev/stdin "$work/flatcar/developer.bin"
  # Exact GPT layout of this pinned developer image: 6 GiB ROOT at sector 4096.
  dd if="$work/flatcar/developer.bin" of="$work/flatcar/rootfs.img" bs=1M skip=2 count=6144 conv=sparse status=progress
  mkdir -p "$work/devroot"
  # Rootless extraction can report ownership errors; files remain owned by builder.
  debugfs -R "rdump / $work/devroot" "$work/flatcar/rootfs.img" > "$work/flatcar/extract.log" 2>&1
  # /usr/bin/gcc is an absolute symlink inside this root, so do not test it
  # against the build host's filesystem when checking the extraction cache.
  test -x "$work/devroot/usr/x86_64-cros-linux-gnu/gcc-bin/15/x86_64-cros-linux-gnu-gcc"
  touch "$work/devroot/.extraction-complete"
fi
mkdir -p "$work/devroot/work"
bwrap --unshare-user --uid 0 --gid 0 \
  --ro-bind "$work/devroot" / --dev /dev --proc /proc \
  --bind "$work" /work --chdir /work/scini-builder \
  /bin/bash -c 'export PATH=/usr/bin:/usr/sbin:/bin:/sbin; export MAKEFLAGS=CC=x86_64-cros-linux-gnu-gcc; x86_64-cros-linux-gnu-gcc --version; ./build_driver.sh -o /work/kernel-build -s /work/kernel-build' \
  2>&1 | tee "$work/logs/scini-build.log"

test -s "$work/scini-builder/ini/scini.ko"
test "$(modinfo -F vermagic "$work/scini-builder/ini/scini.ko")" = '6.12.109-flatcar SMP preempt mod_unload '
out=$work/artifacts/4757.2.0/6.12.109-flatcar
mkdir -p "$out"
cp "$work/scini-builder/ini/scini.ko" "$out/scini.ko"
modinfo "$out/scini.ko" > "$work/logs/scini-modinfo.txt"
sha256sum "$out/scini.ko" "$work/scini-builder.tgz" | tee "$work/logs/scini-sha256.txt"
printf 'Built %s\nRender the deployment with scripts/render-manifest.py after reviewing the build log.\n' "$out/scini.ko"
