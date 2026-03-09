#!/usr/bin/env bash
set -euo pipefail

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[$(ts)] [CONSUMER][INFO] $*"
}

err() {
  echo "[$(ts)] [CONSUMER][ERROR] $*" >&2
}

TARGET_IP="${TARGET_IP:?TARGET_IP required}"
TARGET_PORT="${TARGET_PORT:-3260}"
TARGET_IQN="${TARGET_IQN:?TARGET_IQN required}"
ISCSI_LUN="${ISCSI_LUN:-1}"

FC_TARGET_WWPN="${FC_TARGET_WWPN:-0x500a09c0ffe1aa01}"
FC_TARGET_NODE_WWPN="${FC_TARGET_NODE_WWPN:-0x500a09c0ffe1bb01}"
FC_LUN_ID="${FC_LUN_ID:-0}"
FS_TYPE="${FS_TYPE:-ext4}"

REPO_ROOT="/root/strix-fc"
MOUNT_DIR="/mnt/strix-fc-test"
TEST_FILE="${MOUNT_DIR}/payload.bin"
COPY_FILE="${MOUNT_DIR}/payload.copy"
UDEV_RULE="/etc/udev/rules.d/99-strix-fc.rules"
VENV_DIR="${REPO_ROOT}/.venv"
STRIX_FCCTL="${VENV_DIR}/bin/strix-fcctl"
FCCTL_VERBOSE="${FCCTL_VERBOSE:-0}"
OSBRICK_CONN_FILE="/tmp/strix_fc_osbrick_connection.json"
OSBRICK_CONNECT_LOG="/tmp/strix_fc_osbrick_connect.log"

fcctl() {
  if [[ "${FCCTL_VERBOSE}" == "1" ]]; then
    "${STRIX_FCCTL}" --verbose "$@"
  else
    "${STRIX_FCCTL}" "$@"
  fi
}

cleanup() {
  set +e
  log "Cleanup: unmount"
  timeout 15 umount "${MOUNT_DIR}" >/dev/null 2>&1 || true

  if [[ -n "${FC_DEV:-}" && -b "${FC_DEV}" ]]; then
    log "Cleanup: deleting FC SCSI device ${FC_DEV}"
    timeout 10 blockdev --flushbufs "${FC_DEV}" >/dev/null 2>&1 || true
    timeout 10 udevadm settle >/dev/null 2>&1 || true
    echo 1 > "/sys/block/$(basename "${FC_DEV}")/device/delete" 2>/dev/null || true
    timeout 10 udevadm settle >/dev/null 2>&1 || true
  fi

  if [[ -x "${STRIX_FCCTL}" ]]; then
    log "Cleanup: unmap/delete rport"
    timeout 15 fcctl unmap-lun --host "${HOST_ID:-0}" --target-wwpn "${FC_TARGET_WWPN}" --lun "${FC_LUN_ID}" >/dev/null 2>&1 || true
    timeout 15 fcctl delete-rport --host "${HOST_ID:-0}" --target-wwpn "${FC_TARGET_WWPN}" >/dev/null 2>&1 || true
  fi

  if [[ -f "${OSBRICK_CONN_FILE}" ]]; then
    log "Cleanup: os-brick disconnect"
    timeout 30 "${VENV_DIR}/bin/python" - <<'PY' >/dev/null 2>&1 || true
import json
from os_brick.initiator import connector

conn_file = "/tmp/strix_fc_osbrick_connection.json"
with open(conn_file, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

conn = connector.InitiatorConnector.factory(
    "ISCSI",
  root_helper="sudo",
    use_multipath=False,
    device_scan_attempts=6,
)
conn.disconnect_volume(payload["connection_properties"], payload["device_info"], force=True, ignore_errors=True)
PY
  fi

  log "Cleanup: unload modules"
  timeout 15 modprobe -r strix_fc dm_strix_fc >/dev/null 2>&1 || true
  log "Cleanup: iSCSI logout"
  timeout 20 iscsiadm -m node -T "${TARGET_IQN}" -p "${TARGET_IP}:${TARGET_PORT}" --logout >/dev/null 2>&1 || true
  log "Cleanup: complete"
}
trap cleanup EXIT

export DEBIAN_FRONTEND=noninteractive

log "Installing consumer VM dependencies"
apt-get update
apt-get install -y \
  build-essential \
  gcc \
  make \
  linux-headers-"$(uname -r)" \
  open-iscsi \
  python3 \
  python3-venv \
  python3-yaml \
  udev \
  curl \
  ca-certificates

if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
fi

cd "${REPO_ROOT}"
log "Building kernel modules"
make -j"$(nproc)"

log "Creating Python virtualenv and installing strix-fcctl + os-brick"
uv venv --clear "${VENV_DIR}"
uv pip install --python "${VENV_DIR}/bin/python" -e . os-brick

log "Loading kernel modules"
modprobe dm_mod
modprobe scsi_transport_fc
modprobe dm_strix_fc >/dev/null 2>&1 || insmod ./src/dm_strix_fc/dm_strix_fc.ko
modprobe strix_fc >/dev/null 2>&1 || insmod ./src/strix_fc/strix_fc.ko

log "Starting iSCSI initiator service"
systemctl enable --now iscsid

log "Waiting for target reachability (${TARGET_IP})"
if ! timeout 30 bash -c "until ping -c1 -W1 '${TARGET_IP}' >/dev/null 2>&1; do sleep 1; done"; then
  err "Timed out waiting for ICMP reachability to target ${TARGET_IP}"
  exit 1
fi

log "Discovering and connecting iSCSI volume via os-brick"
if ! timeout 60 "${VENV_DIR}/bin/python" - <<'PY' >"${OSBRICK_CONNECT_LOG}" 2>&1; then
import json
import os
import sys
from os_brick.initiator import connector

portal = f"{os.environ['TARGET_IP']}:{os.environ.get('TARGET_PORT', '3260')}"
props = {
    "target_portal": portal,
    "target_iqn": os.environ["TARGET_IQN"],
    "target_lun": int(os.environ.get("ISCSI_LUN", "1")),
    "access_mode": "rw",
    "discard": False,
}

conn = connector.InitiatorConnector.factory(
    "ISCSI",
  root_helper="sudo",
    use_multipath=False,
    device_scan_attempts=6,
)
device_info = conn.connect_volume(props)

path = device_info.get("path")
if not path:
    candidates = []
    if isinstance(device_info.get("device_path"), str):
        candidates.append(device_info["device_path"])
    if isinstance(device_info.get("devices"), list):
        candidates.extend(device_info["devices"])
    if isinstance(device_info.get("paths"), list):
        candidates.extend(device_info["paths"])
    for candidate in candidates:
        if isinstance(candidate, str) and candidate:
            path = candidate
            break

if not path:
    print(f"os-brick returned device_info without usable path: {device_info}", file=sys.stderr)
    sys.exit(1)

payload = {
    "connection_properties": props,
    "device_info": device_info,
    "resolved_path": path,
}
with open("/tmp/strix_fc_osbrick_connection.json", "w", encoding="utf-8") as handle:
    json.dump(payload, handle)

print(path)
PY
  err "os-brick iSCSI connect failed"
  cat "${OSBRICK_CONNECT_LOG}" >&2 || true
  exit 1
fi

if [[ -s "${OSBRICK_CONNECT_LOG}" ]]; then
  log "os-brick connect output"
  cat "${OSBRICK_CONNECT_LOG}" || true
fi

if [[ ! -f "${OSBRICK_CONN_FILE}" ]]; then
  err "os-brick connection metadata file not created"
  exit 1
fi

if ! BACKING_DEV_RAW="$("${VENV_DIR}/bin/python" - <<'PY'
import json
with open('/tmp/strix_fc_osbrick_connection.json', 'r', encoding='utf-8') as handle:
    payload = json.load(handle)
print(payload.get('resolved_path', ''))
PY
)"; then
  err "Failed reading os-brick connection metadata"
  cat "${OSBRICK_CONN_FILE}" >&2 || true
  exit 1
fi

if [[ -z "${BACKING_DEV_RAW}" ]]; then
  err "os-brick connection metadata did not include resolved_path"
  cat "${OSBRICK_CONN_FILE}" || true
  exit 1
fi

BACKING_DEV="$(readlink -f "${BACKING_DEV_RAW}" 2>/dev/null || true)"
if [[ -z "${BACKING_DEV}" ]]; then
  BACKING_DEV="${BACKING_DEV_RAW}"
fi

if ! timeout 30 bash -c "until [[ -b '${BACKING_DEV}' ]]; do sleep 0.5; done"; then
  err "Resolved os-brick backing device did not appear as block device: ${BACKING_DEV} (raw=${BACKING_DEV_RAW})"
  ls -l /dev/disk/by-path || true
  lsblk -o NAME,SIZE,TYPE,MODEL,VENDOR || true
  exit 1
fi

if [[ -z "${BACKING_DEV}" || ! -b "${BACKING_DEV}" ]]; then
  err "Resolved os-brick backing device is not a block device: ${BACKING_DEV}"
  lsblk -o NAME,SIZE,TYPE,MODEL,VENDOR || true
  exit 1
fi

log "Resolved iSCSI backing device via os-brick ${BACKING_DEV}"

HOST_BASENAME="$(basename "$(ls -1 /sys/class/fc_host | head -n1)")"
HOST_ID="${HOST_BASENAME#host}"

fcctl create-rport --host "${HOST_ID}" --target-wwpn "${FC_TARGET_WWPN}"
fcctl map-lun --host "${HOST_ID}" --target-wwpn "${FC_TARGET_WWPN}" --lun "${FC_LUN_ID}" --backing "${BACKING_DEV}" --dm-name apollo_lxd_test

log "Rescanning FC SCSI devices on host ${HOST_ID}"
for scsi_dev_path in /sys/class/scsi_device/${HOST_ID}:*; do
  [[ -e "${scsi_dev_path}" ]] || continue
  echo 1 > "${scsi_dev_path}/device/rescan" || true
done

cat > "${UDEV_RULE}" <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_PATH}=="*fc-0x*-lun-*", SYMLINK+="strix-fc/%E{ID_PATH}"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd*", ENV{DEVTYPE}=="disk", ATTRS{vendor}=="LUNACY*", ATTRS{model}=="APOLLO FC LUN*", SYMLINK+="strix-fc/%k"
EOF

udevadm control --reload-rules
udevadm trigger --subsystem-match=block
udevadm settle

log "Triggering FC scan for host ${HOST_ID}"
echo "- - -" > "/sys/class/scsi_host/host${HOST_ID}/scan"

FC_BY_PATH_GLOB="/dev/disk/by-path/*-fc-${FC_TARGET_WWPN}-lun-${FC_LUN_ID}"
FC_DEV=""
FC_CANDIDATES=()

if timeout 30 bash -c "until ls ${FC_BY_PATH_GLOB} >/dev/null 2>&1; do sleep 0.5; done"; then
  while IFS= read -r candidate; do
    FC_CANDIDATES+=("${candidate}")
  done < <(readlink -f ${FC_BY_PATH_GLOB} 2>/dev/null || true)
fi

if [[ -z "${FC_DEV}" ]]; then
  if timeout 30 bash -c "until ls /dev/strix-fc/* >/dev/null 2>&1; do sleep 0.5; done"; then
    while IFS= read -r candidate; do
      FC_CANDIDATES+=("${candidate}")
    done < <(readlink -f /dev/strix-fc/* 2>/dev/null || true)
  fi
fi

log "Discovered FC by-path entries (/dev/disk/by-path/*fc-*)"
ls -l /dev/disk/by-path/*fc-* 2>/dev/null || true

log "Discovered Strix FC entries (/dev/strix-fc/*)"
ls -l /dev/strix-fc/* 2>/dev/null || true

for candidate in "${FC_CANDIDATES[@]}"; do
  if [[ -b "${candidate}" ]] && [[ "$(blockdev --getsize64 "${candidate}")" -gt 0 ]]; then
    FC_DEV="${candidate}"
    break
  fi
done

if [[ -z "${FC_DEV}" || ! -b "${FC_DEV}" ]]; then
  err "Could not resolve FC block device from by-path or strix-fc udev links"
  ls -l /dev/disk/by-path || true
  ls -l /dev/strix-fc || true
  lsblk -o NAME,SIZE,TYPE,MODEL,VENDOR || true
  exit 1
fi

log "Selected FC block device ${FC_DEV}"

log "Formatting and mounting filesystem (fs=${FS_TYPE})"
if [[ "${FS_TYPE}" == "ext4" ]]; then
  MKFS_CMD=(
    mkfs.ext4
    -F
    -E nodiscard,assume_storage_prezeroed=1,lazy_itable_init=1,lazy_journal_init=1
    "${FC_DEV}"
  )
elif [[ "${FS_TYPE}" == "ext2" ]]; then
  MKFS_CMD=(mkfs.ext2 -F "${FC_DEV}")
else
  err "Unsupported FS_TYPE=${FS_TYPE}; supported: ext2, ext4"
  exit 1
fi

if ! timeout 120 "${MKFS_CMD[@]}"; then
  err "mkfs (${FS_TYPE}) failed or timed out on ${FC_DEV}"
  blockdev --getsize64 "${FC_DEV}" || true
  lsblk -o NAME,SIZE,TYPE,MODEL,VENDOR || true
  dmesg -T | tail -n 120 || true
  exit 1
fi
mkdir -p "${MOUNT_DIR}"
mount "${FC_DEV}" "${MOUNT_DIR}"

log "Writing and validating data"
dd if=/dev/urandom of="${TEST_FILE}" bs=1M count=8 status=none
cp "${TEST_FILE}" "${COPY_FILE}"
sync

SUM_A="$(sha256sum "${TEST_FILE}" | awk '{print $1}')"
SUM_B="$(sha256sum "${COPY_FILE}" | awk '{print $1}')"

if [[ "${SUM_A}" != "${SUM_B}" ]]; then
  err "Data checksum mismatch after filesystem write/read"
  exit 1
fi

echo "[$(ts)] [CONSUMER] backing_dev=${BACKING_DEV} fc_dev=${FC_DEV} checksum=${SUM_A}"
echo "[$(ts)] [PASS] Strix FC LXD os-brick consumer test passed"
