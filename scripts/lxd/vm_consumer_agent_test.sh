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

REPO_ROOT="/root/apollo-fc"
VENV_DIR="${REPO_ROOT}/.venv"
GATEWAY_URL="http://${TARGET_IP}:${GATEWAY_PORT}"

cleanup() {
  set +e
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
  python3 python3-pip python3-venv python3-yaml \
  curl jq

cd "${REPO_ROOT}"

log "Building kernel modules"
make -j"$(nproc)"

log "Creating Python virtualenv and installing apollo-fcctl + agent"
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/python" -m pip install --upgrade pip
"${VENV_DIR}/bin/python" -m pip install -e .

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

log "E2E agent test PASSED"
