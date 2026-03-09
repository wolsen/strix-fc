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
FC_OSBRICK_CONN_FILE="/tmp/strix_fc_fc_osbrick_connection.json"
FC_OSBRICK_CONNECT_LOG="/tmp/strix_fc_fc_osbrick_connect.log"

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

  if [[ -f "${FC_OSBRICK_CONN_FILE}" ]]; then
    log "Cleanup: os-brick FC disconnect"
    timeout 30 "${VENV_DIR}/bin/python" - <<'PY' >/dev/null 2>&1 || true
import json
from os_brick.initiator import connector
from oslo_concurrency import lockutils

lockutils.set_defaults('/tmp')

with open('/tmp/strix_fc_fc_osbrick_connection.json', 'r', encoding='utf-8') as handle:
    payload = json.load(handle)

conn = None
for protocol in ('FC', 'FIBRE_CHANNEL', 'fibre_channel'):
  try:
    conn = connector.InitiatorConnector.factory(
      protocol,
      root_helper='sudo',
      use_multipath=False,
      device_scan_attempts=6,
    )
    break
  except Exception:
    continue

if conn is None:
  raise RuntimeError('No supported os-brick FC protocol name found')

conn.disconnect_volume(payload['connection_properties'], payload['device_info'], force=True, ignore_errors=True)
PY
  fi

  if [[ -x "${STRIX_FCCTL}" ]]; then
    log "Cleanup: unmap/delete rport"
    timeout 15 fcctl unmap-lun --host "${HOST_ID:-0}" --target-wwpn "${FC_TARGET_WWPN}" --lun "${FC_LUN_ID}" >/dev/null 2>&1 || true
    timeout 15 fcctl delete-rport --host "${HOST_ID:-0}" --target-wwpn "${FC_TARGET_WWPN}" >/dev/null 2>&1 || true
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
  sudo \
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
ln -sf "${VENV_DIR}/bin/privsep-helper" /usr/local/bin/privsep-helper

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

DISCOVERY_OK=0
for _ in {1..10}; do
  if iscsiadm -m discovery -t sendtargets -p "${TARGET_IP}:${TARGET_PORT}"; then
    DISCOVERY_OK=1
    break
  fi
  sleep 2
done

if [[ "${DISCOVERY_OK}" -ne 1 ]]; then
  err "Unable to discover iSCSI target at ${TARGET_IP}:${TARGET_PORT}"
  exit 1
fi

log "Logging into iSCSI target ${TARGET_IQN}"
iscsiadm -m node -T "${TARGET_IQN}" -p "${TARGET_IP}:${TARGET_PORT}" --login

ISCSI_PATH="/dev/disk/by-path/ip-${TARGET_IP}:${TARGET_PORT}-iscsi-${TARGET_IQN}-lun-${ISCSI_LUN}"
log "Waiting for iSCSI block path ${ISCSI_PATH}"
if ! timeout 30 bash -c "until [[ -e '${ISCSI_PATH}' ]]; do sleep 0.5; done"; then
  err "Timed out waiting for iSCSI block device path ${ISCSI_PATH}"
  ls -l /dev/disk/by-path || true
  exit 1
fi

BACKING_DEV="$(readlink -f "${ISCSI_PATH}")"
log "Resolved iSCSI backing device ${BACKING_DEV}"

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
log "Discovered FC by-path entries (/dev/disk/by-path/*fc-*)"
ls -l /dev/disk/by-path/*fc-* 2>/dev/null || true

log "Discovered Strix FC entries (/dev/strix-fc/*)"
ls -l /dev/strix-fc/* 2>/dev/null || true

if ! ls /dev/disk/by-path/*fc-* >/dev/null 2>&1; then
  FC_HINT_DEV="$(readlink -f /dev/strix-fc/* 2>/dev/null | head -n1 || true)"
  FC_WWPN_HEX="${FC_TARGET_WWPN#0x}"
  if [[ -n "${FC_HINT_DEV}" ]]; then
    ln -sf "../../$(basename "${FC_HINT_DEV}")" "/dev/disk/by-path/strix-fc-0x${FC_WWPN_HEX}-lun-${FC_LUN_ID}" || true
    ln -sf "../../$(basename "${FC_HINT_DEV}")" "/dev/disk/by-path/strix-fc-${FC_WWPN_HEX}-lun-${FC_LUN_ID}" || true
    log "Synthesized FC by-path entries for os-brick discovery"
    ls -l /dev/disk/by-path/*fc-* 2>/dev/null || true
  fi
fi

log "Discovering FC device via os-brick FC connector"
if ! timeout 60 "${VENV_DIR}/bin/python" - <<'PY' >"${FC_OSBRICK_CONNECT_LOG}" 2>&1; then
import json
import os
import sys
import glob
from os_brick.initiator import connector
from os_brick import initializer as os_brick_initializer
from oslo_concurrency import lockutils

lockutils.set_defaults('/tmp')

wwpn = os.environ['FC_TARGET_WWPN'].lower()
if wwpn.startswith('0x'):
    wwpn = wwpn[2:]
lun = int(os.environ.get('FC_LUN_ID', '0'))
props = {
    'target_discovered': True,
    'target_wwn': [wwpn],
    'target_lun': lun,
    'target_wwns': [wwpn],
    'target_luns': [lun],
  'targets': [(wwpn, lun)],
    'access_mode': 'rw',
}

conn = None
os_brick_initializer.setup(root_helper='sudo')
for protocol in ('FC', 'FIBRE_CHANNEL', 'fibre_channel'):
  try:
    conn = connector.InitiatorConnector.factory(
      protocol,
      root_helper='sudo',
      use_multipath=False,
      device_scan_attempts=6,
    )
    break
  except Exception:
    continue

if conn is None:
  print('No supported os-brick FC protocol name found', file=sys.stderr)
  sys.exit(1)

hbas = conn._linuxfc.get_fc_hbas_info()
expected_host_paths = conn._get_possible_volume_paths(props, hbas)
for host_path in expected_host_paths:
  print(f'expected_fc_host_path={host_path}')

hint_paths = [os.path.realpath(p) for p in glob.glob('/dev/strix-fc/*') if os.path.exists(p)]
hint_device = hint_paths[0] if hint_paths else None

if hint_device:
  for host_path in expected_host_paths:
    if os.path.exists(host_path):
      continue
    parent = os.path.dirname(host_path)
    os.makedirs(parent, exist_ok=True)
    rel_target = os.path.relpath(hint_device, parent)
    try:
      os.symlink(rel_target, host_path)
      print(f'synthesized_fc_host_path={host_path}->{rel_target}')
    except FileExistsError:
      pass

try:
  device_info = conn.connect_volume(props)
except Exception as exc:
  if 'FailedToDropPrivileges' not in type(exc).__name__:
    raise

  paths = []
  if hasattr(conn, 'get_volume_paths'):
    paths = conn.get_volume_paths(props) or []

  path = paths[0] if paths else None
  if not path and hasattr(conn, 'get_device_path'):
    path = conn.get_device_path(props)

  if not path:
    raise

  device_info = {
    'path': path,
    'devices': paths,
    'fallback': 'path-only',
  }

path = device_info.get('path') or device_info.get('device_path')
if not path:
    devices = device_info.get('devices') or device_info.get('paths') or []
    if devices:
        path = devices[0]

if not path:
    print(f'os-brick FC connect returned no usable path: {device_info}', file=sys.stderr)
    sys.exit(1)

payload = {
    'connection_properties': props,
    'device_info': device_info,
    'resolved_path': path,
}
with open('/tmp/strix_fc_fc_osbrick_connection.json', 'w', encoding='utf-8') as handle:
    json.dump(payload, handle)

print(path)
PY
  err "os-brick FC connect failed"
  cat "${FC_OSBRICK_CONNECT_LOG}" >&2 || true
  exit 1
fi

if [[ -s "${FC_OSBRICK_CONNECT_LOG}" ]]; then
  log "os-brick FC connector output"
  cat "${FC_OSBRICK_CONNECT_LOG}" || true
fi

if [[ ! -f "${FC_OSBRICK_CONN_FILE}" ]]; then
  err "FC os-brick connection metadata file not created"
  exit 1
fi

if ! FC_DEV_RAW="$("${VENV_DIR}/bin/python" - <<'PY'
import json
with open('/tmp/strix_fc_fc_osbrick_connection.json', 'r', encoding='utf-8') as handle:
    payload = json.load(handle)
print(payload.get('resolved_path', ''))
PY
)"; then
  err "Failed reading FC os-brick connection metadata"
  cat "${FC_OSBRICK_CONN_FILE}" >&2 || true
  exit 1
fi

if [[ -z "${FC_DEV_RAW}" ]]; then
  err "FC os-brick metadata did not include resolved_path"
  cat "${FC_OSBRICK_CONN_FILE}" || true
  exit 1
fi

FC_DEV="$(readlink -f "${FC_DEV_RAW}" 2>/dev/null || true)"
if [[ -z "${FC_DEV}" ]]; then
  FC_DEV="${FC_DEV_RAW}"
fi

if ! timeout 30 bash -c "until [[ -b '${FC_DEV}' ]]; do sleep 0.5; done"; then
  err "Resolved FC os-brick device did not appear as block device: ${FC_DEV} (raw=${FC_DEV_RAW})"
  ls -l /dev/disk/by-path || true
  lsblk -o NAME,SIZE,TYPE,MODEL,VENDOR || true
  exit 1
fi

log "Selected FC block device via os-brick ${FC_DEV}"

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
echo "[$(ts)] [PASS] Strix FC LXD os-brick FC consumer test passed"
