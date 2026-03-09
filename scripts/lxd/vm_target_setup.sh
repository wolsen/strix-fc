#!/usr/bin/env bash
set -euo pipefail

ts() {
	date '+%Y-%m-%d %H:%M:%S'
}

log() {
	echo "[$(ts)] [TARGET][INFO] $*"
}

err() {
	echo "[$(ts)] [TARGET][ERROR] $*" >&2
}

TARGET_IQN="${TARGET_IQN:-iqn.2026-03.com.lunacy:apollo.fc.test}"
TARGET_PORT="${TARGET_PORT:-3260}"
ISCSI_LUN="${ISCSI_LUN:-1}"
TARGET_LUN_SIZE_MB="${TARGET_LUN_SIZE_MB:-512}"
BACKING_FILE="/var/lib/strix-fc/target-lun.img"
BACKSTORE_NAME="strix_fc_lun"

export DEBIAN_FRONTEND=noninteractive

log "Installing target VM dependencies"
apt-get update
apt-get install -y targetcli-fb

log "Loading target kernel modules"
modprobe target_core_mod
modprobe iscsi_target_mod

log "Preparing backing image ${BACKING_FILE}"
mkdir -p /var/lib/strix-fc
truncate -s "${TARGET_LUN_SIZE_MB}M" "${BACKING_FILE}"

log "Configuring targetcli objects"
targetcli clearconfig confirm=True

targetcli /backstores/fileio create "${BACKSTORE_NAME}" "${BACKING_FILE}" "${TARGET_LUN_SIZE_MB}M" write_back=false
targetcli /iscsi create "${TARGET_IQN}"
targetcli "/iscsi/${TARGET_IQN}/tpg1/portals" create 0.0.0.0 "${TARGET_PORT}" >/dev/null 2>&1 || true
targetcli "/iscsi/${TARGET_IQN}/tpg1/luns" create "/backstores/fileio/${BACKSTORE_NAME}" "${ISCSI_LUN}"
targetcli "/iscsi/${TARGET_IQN}/tpg1" set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1 demo_mode_discovery=1

targetcli saveconfig

if ! ss -lnt | grep -q ":${TARGET_PORT} "; then
	err "iSCSI target portal is not listening on port ${TARGET_PORT}"
	targetcli ls
	exit 1
fi

echo "[$(ts)] [TARGET] iqn=${TARGET_IQN} port=${TARGET_PORT} lun=${ISCSI_LUN} file=${BACKING_FILE}"
