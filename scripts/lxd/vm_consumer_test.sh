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

REPO_ROOT="/root/apollo-fc"
MOUNT_DIR="/mnt/apollo-fc-test"
TEST_FILE="${MOUNT_DIR}/payload.bin"
COPY_FILE="${MOUNT_DIR}/payload.copy"
UDEV_RULE="/etc/udev/rules.d/99-apollo-fc.rules"
VENV_DIR="${REPO_ROOT}/.venv"
APOLLO_FCCTL="${VENV_DIR}/bin/apollo-fcctl"
FCCTL_VERBOSE="${FCCTL_VERBOSE:-0}"

fcctl() {
  if [[ "${FCCTL_VERBOSE}" == "1" ]]; then
    "${APOLLO_FCCTL}" --verbose "$@"
  else
    "${APOLLO_FCCTL}" "$@"
  fi
}

cleanup() {
  set +e
  log "Cleanup: unmount"
  timeout 15 umount "${MOUNT_DIR}" >/dev/null 2>&1 || true
  if [[ -x "${APOLLO_FCCTL}" ]]; then
    log "Cleanup: unmap/delete rport"
    timeout 15 fcctl unmap-lun --host "${HOST_ID:-0}" --target-wwpn "${FC_TARGET_WWPN}" --lun "${FC_LUN_ID}" >/dev/null 2>&1 || true
    timeout 15 fcctl delete-rport --host "${HOST_ID:-0}" --target-wwpn "${FC_TARGET_WWPN}" >/dev/null 2>&1 || true
  fi
  log "Cleanup: unload modules"
  timeout 15 modprobe -r apollo_fc dm_apollo_fc >/dev/null 2>&1 || true
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
  python3-pip \
  python3-venv \
  python3-yaml \
  udev

cd "${REPO_ROOT}"
log "Building kernel modules"
make -j"$(nproc)"

log "Creating Python virtualenv and installing apollo-fcctl"
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/python" -m pip install --upgrade pip
"${VENV_DIR}/bin/python" -m pip install -e .

log "Loading kernel modules"
modprobe dm_mod
modprobe scsi_transport_fc
insmod ./src/dm_apollo_fc/dm_apollo_fc.ko
insmod ./src/apollo_fc/apollo_fc.ko

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
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_PATH}=="*fc-0x*-lun-*", SYMLINK+="apollo-fc/%E{ID_PATH}"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd*", ENV{DEVTYPE}=="disk", ATTRS{vendor}=="LUNACY*", ATTRS{model}=="APOLLO FC LUN*", SYMLINK+="apollo-fc/%k"
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
  if timeout 30 bash -c "until ls /dev/apollo-fc/* >/dev/null 2>&1; do sleep 0.5; done"; then
    while IFS= read -r candidate; do
      FC_CANDIDATES+=("${candidate}")
    done < <(readlink -f /dev/apollo-fc/* 2>/dev/null || true)
  fi
fi

log "Discovered FC by-path entries (/dev/disk/by-path/*fc-*)"
ls -l /dev/disk/by-path/*fc-* 2>/dev/null || true

log "Discovered Apollo FC entries (/dev/apollo-fc/*)"
ls -l /dev/apollo-fc/* 2>/dev/null || true

for candidate in "${FC_CANDIDATES[@]}"; do
  if [[ -b "${candidate}" ]] && [[ "$(blockdev --getsize64 "${candidate}")" -gt 0 ]]; then
    FC_DEV="${candidate}"
    break
  fi
done

if [[ -z "${FC_DEV}" || ! -b "${FC_DEV}" ]]; then
  err "Could not resolve FC block device from by-path or apollo-fc udev links"
  ls -l /dev/disk/by-path || true
  ls -l /dev/apollo-fc || true
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
echo "[$(ts)] [PASS] Apollo FC LXD consumer test passed"
