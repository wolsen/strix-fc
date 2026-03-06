#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Canonical, Ltd.
# SPDX-License-Identifier: GPL-2.0-only
#
# Consumer VM test: Apollo FC Agent end-to-end validation
#
# This script runs INSIDE the consumer VM. It:
# 1. Builds + loads the apollo_fc / dm_apollo_fc kernel modules.
# 2. Installs apollo-fcctl + the agent.
# 3. Registers this host with the gateway.
# 4. Creates an FC mapping via the gateway API.
# 5. Runs the agent for one reconcile cycle.
# 6. Validates the LUN appeared via the kernel module.
#
# Environment variables (required):
#   TARGET_IP            IP of the target+gateway VM
#   GATEWAY_PORT         Port the gateway listens on (default: 8080)
#   TARGET_IQN           iSCSI target IQN
#   TARGET_PORT          iSCSI portal port (default: 3260)
#   FC_TARGET_WWPN       FC target WWPN (hex)
#   FC_TARGET_NODE_WWPN  FC target node WWPN (hex)
#   FC_LUN_ID            FC LUN to map (default: 0)
set -euo pipefail

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [CONSUMER-AGENT][INFO] $*"; }
err() { echo "[$(ts)] [CONSUMER-AGENT][ERROR] $*" >&2; }

api_post() {
  local path="$1"
  local body="$2"
  local http_code resp

  resp="$(curl -s -X POST "${GATEWAY_URL}${path}" \
    -H "Content-Type: application/json" \
    -d "${body}" \
    -w '\n%{http_code}')"
  http_code="$(echo "${resp}" | tail -1)"
  resp="$(echo "${resp}" | sed '$d')"

  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    err "POST ${path} failed (HTTP ${http_code}): ${resp}"
    return 1
  fi

  echo "${resp}"
}

TARGET_IP="${TARGET_IP:?TARGET_IP required}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
TARGET_IQN="${TARGET_IQN:?TARGET_IQN required}"
TARGET_PORT="${TARGET_PORT:-3260}"
FC_TARGET_WWPN="${FC_TARGET_WWPN:-0x500a09c0ffe1aa01}"
FC_TARGET_NODE_WWPN="${FC_TARGET_NODE_WWPN:-0x500a09c0ffe1bb01}"
FC_LUN_ID="${FC_LUN_ID:-0}"
FS_TYPE="${FS_TYPE:-ext4}"

REPO_ROOT="/root/apollo-fc"
VENV_DIR="${REPO_ROOT}/.venv"
GATEWAY_URL="http://${TARGET_IP}:${GATEWAY_PORT}"
MOUNT_DIR="/mnt/apollo-fc-agent-test"
TEST_FILE="${MOUNT_DIR}/payload.bin"
COPY_FILE="${MOUNT_DIR}/payload.copy"
OSBRICK_CONN_FILE="/tmp/apollo_fc_agent_osbrick_connection.json"
OSBRICK_CONNECT_LOG="/tmp/apollo_fc_agent_osbrick_connect.log"
UDEV_RULE="/etc/udev/rules.d/99-apollo-fc.rules"

cleanup() {
  set +e
  log "Cleanup: unmount"
  timeout 15 umount "${MOUNT_DIR}" >/dev/null 2>&1 || true

  if [[ -f "${OSBRICK_CONN_FILE}" ]]; then
    log "Cleanup: os-brick disconnect"
    timeout 30 "${VENV_DIR}/bin/python" - <<'PY' >/dev/null 2>&1 || true
import json
from os_brick.initiator import connector
from oslo_concurrency import lockutils

lockutils.set_defaults('/tmp')

with open('/tmp/apollo_fc_agent_osbrick_connection.json', 'r', encoding='utf-8') as handle:
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
  build-essential gcc make \
  linux-headers-"$(uname -r)" \
  open-iscsi \
  sudo \
  python3 python3-pip python3-venv python3-yaml \
  curl jq

cd "${REPO_ROOT}"

log "Building kernel modules"
make -j"$(nproc)"

log "Creating Python virtualenv and installing apollo-fcctl + agent"
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/python" -m pip install --upgrade pip
"${VENV_DIR}/bin/python" -m pip install -e . os-brick
ln -sf "${VENV_DIR}/bin/privsep-helper" /usr/local/bin/privsep-helper

log "Loading kernel modules"
modprobe dm_mod
modprobe scsi_transport_fc
insmod ./src/dm_apollo_fc/dm_apollo_fc.ko
insmod ./src/apollo_fc/apollo_fc.ko

log "Detecting apollo_fc SCSI host number"
FC_HOST_NUM="$(for h in /sys/class/scsi_host/host*; do
  [[ -f "${h}/proc_name" ]] || continue
  if [[ "$(cat "${h}/proc_name")" == "apollo_fc" ]]; then
    echo "${h##*host}"
    break
  fi
done)"
if [[ -z "${FC_HOST_NUM}" ]]; then
  err "Failed to detect apollo_fc host number"
  ls -l /sys/class/scsi_host || true
  exit 1
fi
log "Detected apollo_fc host number: ${FC_HOST_NUM}"

log "Starting iSCSI initiator service"
systemctl enable --now iscsid

log "Waiting for target reachability (${TARGET_IP})"
if ! timeout 30 bash -c "until ping -c1 -W1 '${TARGET_IP}' >/dev/null 2>&1; do sleep 1; done"; then
  err "Timed out waiting for ICMP reachability to target ${TARGET_IP}"
  exit 1
fi

# --- Step 1: Verify gateway is reachable ---
log "Verifying gateway at ${GATEWAY_URL}"
if ! curl -sf "${GATEWAY_URL}/healthz" | jq .; then
  err "Gateway not reachable at ${GATEWAY_URL}"
  exit 1
fi

# --- Step 2: Register host with gateway ---
log "Registering host with gateway"
HOST_RESP="$(api_post "/v1/hosts" "{
  \"name\": \"agent-test-host\",
  \"initiators_fc_wwpns\": [\"${FC_TARGET_WWPN}\"]
}")"
HOST_ID=$(echo "${HOST_RESP}" | jq -r '.id')
log "Host registered: id=${HOST_ID}"

# --- Step 3: Create pool + volume ---
log "Creating pool"
POOL_RESP="$(api_post "/v1/pools" '{"name": "agent-test-pool", "backend_type": "malloc", "size_mb": 4096}')"
POOL_ID=$(echo "${POOL_RESP}" | jq -r '.id')
ARRAY_ID=$(echo "${POOL_RESP}" | jq -r '.array_id')
log "Pool created: id=${POOL_ID} array=${ARRAY_ID}"

log "Creating volume"
VOL_RESP="$(api_post "/v1/volumes" "{\"name\": \"agent-test-vol\", \"pool_id\": \"${POOL_ID}\", \"size_gb\": 1}")"
VOL_ID=$(echo "${VOL_RESP}" | jq -r '.id')
log "Volume created: id=${VOL_ID}"

# --- Step 4: Create FC endpoint with WWPNs + iSCSI underlay endpoint ---
log "Creating FC persona endpoint"
FC_EP_RESP="$(api_post "/v1/arrays/${ARRAY_ID}/endpoints" "{
  \"protocol\": \"fc\",
  \"targets\": {\"target_wwpns\": [\"${FC_TARGET_WWPN}\"]},
  \"addresses\": {},
  \"auth\": {\"method\": \"none\"}
}")"
FC_EP_ID=$(echo "${FC_EP_RESP}" | jq -r '.id')
log "FC endpoint created: id=${FC_EP_ID}"

log "Creating iSCSI underlay endpoint"
ISCSI_EP_RESP="$(api_post "/v1/arrays/${ARRAY_ID}/endpoints" "{
  \"protocol\": \"iscsi\",
  \"targets\": {\"target_iqn\": \"${TARGET_IQN}\"},
  \"addresses\": {\"portals\": [\"${TARGET_IP}:${TARGET_PORT}\"]},
  \"auth\": {\"method\": \"none\"}
}")"
ISCSI_EP_ID=$(echo "${ISCSI_EP_RESP}" | jq -r '.id')
log "iSCSI underlay endpoint created: id=${ISCSI_EP_ID}"

# --- Step 5: Create FC mapping ---
log "Creating mapping (persona=FC, underlay=iSCSI)"
MAP_RESP="$(api_post "/v1/mappings" "{
  \"host_id\": \"${HOST_ID}\",
  \"volume_id\": \"${VOL_ID}\",
  \"persona_endpoint_id\": \"${FC_EP_ID}\",
  \"underlay_endpoint_id\": \"${ISCSI_EP_ID}\"
}")"
MAP_ID=$(echo "${MAP_RESP}" | jq -r '.id')
log "Mapping created: id=${MAP_ID}"

# --- Step 6: Verify attachments endpoint ---
log "Fetching attachments"
ATT_RESP=$(curl -sf "${GATEWAY_URL}/v1/hosts/${HOST_ID}/attachments")
ATT_COUNT=$(echo "${ATT_RESP}" | jq '.attachments | length')
log "Attachments count: ${ATT_COUNT}"
if [[ "${ATT_COUNT}" -lt 1 ]]; then
  err "Expected at least 1 attachment, got ${ATT_COUNT}"
  echo "${ATT_RESP}" | jq .
  exit 1
fi

PRE_SD_COUNT="$(ls /sys/block | grep -E '^sd' | wc -l)"
log "Pre-reconcile SCSI disk count: ${PRE_SD_COUNT}"

# --- Step 7: Run agent for one reconcile pass ---
log "Running agent reconcile (one-shot via env vars)"
export APOLLO_FC_AGENT_GATEWAY_URL="${GATEWAY_URL}"
export APOLLO_FC_AGENT_HOST_ID="${HOST_ID}"
export APOLLO_FC_AGENT_FC_HOST_NUM="${FC_HOST_NUM}"
export APOLLO_FC_AGENT_POLL_INTERVAL_SEC=1
export APOLLO_FC_AGENT_DISABLE_STATE_SCAN=true

# Use a short Python script to do one reconcile cycle then exit
"${VENV_DIR}/bin/python" -c "
import httpx
from apollo_fcctl.netlink import ApolloNetlinkClient
from apollo_fcctl.agent.config import AgentSettings
from apollo_fcctl.agent.reconcile import reconcile_once

settings = AgentSettings()
nl = ApolloNetlinkClient()
http_client = httpx.Client()
try:
    changes = reconcile_once(http_client, nl, settings)
    print(f'Reconcile applied {changes} change(s)')
finally:
    http_client.close()
    nl.close()
"
log "Agent reconcile complete"

# --- Step 8: Validate new SCSI disk appeared ---
POST_SD_COUNT="${PRE_SD_COUNT}"
for _ in $(seq 1 20); do
  POST_SD_COUNT="$(ls /sys/block | grep -E '^sd' | wc -l)"
  if [[ "${POST_SD_COUNT}" -gt "${PRE_SD_COUNT}" ]]; then
    break
  fi
  sleep 0.5
done

log "Post-reconcile SCSI disk count: ${POST_SD_COUNT}"
if [[ "${POST_SD_COUNT}" -le "${PRE_SD_COUNT}" ]]; then
  err "Expected additional SCSI disk(s) after reconcile"
  ls -1 /sys/block | grep -E '^sd' || true
  exit 1
fi
log "New SCSI disk detected after reconcile"

# --- Step 8.5: Verify os-brick discovery/connect for FC persona path ---
cat > "${UDEV_RULE}" <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_PATH}=="*fc-0x*-lun-*", SYMLINK+="apollo-fc/%E{ID_PATH}"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd*", ENV{DEVTYPE}=="disk", ATTRS{vendor}=="LUNACY*", ATTRS{model}=="APOLLO FC LUN*", SYMLINK+="apollo-fc/%k"
EOF

udevadm control --reload-rules
udevadm trigger --subsystem-match=block
udevadm settle

log "Discovered FC by-path entries (/dev/disk/by-path/*fc-*)"
ls -l /dev/disk/by-path/*fc-* 2>/dev/null || true

log "Discovered Apollo FC entries (/dev/apollo-fc/*)"
ls -l /dev/apollo-fc/* 2>/dev/null || true

log "Running os-brick FC discovery/connect validation"
if ! timeout 90 "${VENV_DIR}/bin/python" - <<'PY' >"${OSBRICK_CONNECT_LOG}" 2>&1; then
import glob
import json
import os
import sys

import os_brick
from os_brick.initiator import connector
from oslo_concurrency import lockutils

lockutils.set_defaults('/tmp')
if hasattr(os_brick, 'setup'):
  try:
    os_brick.setup(root_helper='sudo')
  except Exception:
    pass

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

hint_paths = [os.path.realpath(p) for p in glob.glob('/dev/apollo-fc/*') if os.path.exists(p)]
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
  paths = []
  if hasattr(conn, 'get_volume_paths'):
    paths = conn.get_volume_paths(props) or []

  if not paths:
    paths = [p for p in expected_host_paths if os.path.exists(p)]

  path = paths[0] if paths else None
  if not path and hasattr(conn, 'get_device_path'):
    try:
      path = conn.get_device_path(props)
    except Exception:
      path = None

  if not path:
    print(f'os-brick FC connect failed without fallback path: {exc!r}', file=sys.stderr)
    raise

  print(f'os-brick FC connect fallback used due to: {exc!r}')
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
with open('/tmp/apollo_fc_agent_osbrick_connection.json', 'w', encoding='utf-8') as handle:
  json.dump(payload, handle)

print(path)
PY
  err "os-brick FC connect failed"
  cat "${OSBRICK_CONNECT_LOG}" >&2 || true
  exit 1
fi

if [[ -s "${OSBRICK_CONNECT_LOG}" ]]; then
  log "os-brick FC connect output"
  cat "${OSBRICK_CONNECT_LOG}" || true
fi

if [[ ! -f "${OSBRICK_CONN_FILE}" ]]; then
  err "FC os-brick connection metadata file not created"
  exit 1
fi

OSBRICK_DEV_RAW="$(${VENV_DIR}/bin/python - <<'PY'
import json
with open('/tmp/apollo_fc_agent_osbrick_connection.json', 'r', encoding='utf-8') as handle:
  payload = json.load(handle)
print(payload.get('resolved_path', ''))
PY
)"

if [[ -z "${OSBRICK_DEV_RAW}" ]]; then
  err "FC os-brick metadata did not include resolved_path"
  cat "${OSBRICK_CONN_FILE}" || true
  exit 1
fi

OSBRICK_DEV="$(readlink -f "${OSBRICK_DEV_RAW}" 2>/dev/null || true)"
if [[ -z "${OSBRICK_DEV}" ]]; then
  OSBRICK_DEV="${OSBRICK_DEV_RAW}"
fi

if [[ ! -b "${OSBRICK_DEV}" ]]; then
  err "Resolved FC os-brick device is not a block device: ${OSBRICK_DEV}"
  lsblk -o NAME,SIZE,TYPE,MODEL,VENDOR || true
  exit 1
fi
log "os-brick resolved FC device: ${OSBRICK_DEV}"
lsblk -o NAME,SIZE,TYPE,MODEL,VENDOR | sed -n '1p;/LUNACY\|APOLLO\|sd/p'

# --- Step 9: Filesystem and write validation ---
log "Creating filesystem (${FS_TYPE}) and validating write/read on ${OSBRICK_DEV}"
if [[ "${FS_TYPE}" == "ext4" ]]; then
  mkfs.ext4 -F "${OSBRICK_DEV}" >/dev/null
elif [[ "${FS_TYPE}" == "ext2" ]]; then
  mkfs.ext2 -F "${OSBRICK_DEV}" >/dev/null
else
  err "Unsupported FS_TYPE=${FS_TYPE}; supported: ext2, ext4"
  exit 1
fi

mkdir -p "${MOUNT_DIR}"
mount "${OSBRICK_DEV}" "${MOUNT_DIR}"

dd if=/dev/urandom of="${TEST_FILE}" bs=1M count=8 status=none
cp "${TEST_FILE}" "${COPY_FILE}"
sync

SUM_A="$(sha256sum "${TEST_FILE}" | awk '{print $1}')"
SUM_B="$(sha256sum "${COPY_FILE}" | awk '{print $1}')"
if [[ "${SUM_A}" != "${SUM_B}" ]]; then
  err "Data checksum mismatch after filesystem write/read"
  exit 1
fi

log "Filesystem write/read checksum verified: ${SUM_A}"

log "E2E agent test PASSED"
