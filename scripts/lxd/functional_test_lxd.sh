#!/usr/bin/env bash
set -euo pipefail

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[$(ts)] [INFO] $*"
}

err() {
  echo "[$(ts)] [ERROR] $*" >&2
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TARGET_VM="${TARGET_VM:-apollo-fc-target}"
CONSUMER_VM="${CONSUMER_VM:-apollo-fc-consumer}"
IMAGE="${LXD_IMAGE:-ubuntu:24.04}"
KEEP_VMS="${KEEP_VMS:-0}"
VM_MEMORY="${VM_MEMORY:-4GiB}"
VM_CPUS="${VM_CPUS:-2}"

TARGET_IQN="${TARGET_IQN:-iqn.2026-03.com.lunacy:apollo.fc.test}"
TARGET_PORT="${TARGET_PORT:-3260}"
ISCSI_LUN="${ISCSI_LUN:-1}"
TARGET_LUN_SIZE_MB="${TARGET_LUN_SIZE_MB:-512}"

FC_TARGET_WWPN="${FC_TARGET_WWPN:-0x500a09c0ffe1aa01}"
FC_TARGET_NODE_WWPN="${FC_TARGET_NODE_WWPN:-0x500a09c0ffe1bb01}"
FC_LUN_ID="${FC_LUN_ID:-0}"
CONSUMER_TEST_SCRIPT="${CONSUMER_TEST_SCRIPT:-vm_consumer_test.sh}"

cleanup() {
  local rc=$?

  if [[ "${KEEP_VMS}" == "1" ]]; then
    log "KEEP_VMS=1, leaving VMs running: ${TARGET_VM}, ${CONSUMER_VM}"
    return
  fi

  log "Cleaning up LXD VMs"
  lxc delete -f "${CONSUMER_VM}" >/dev/null 2>&1 || true
  lxc delete -f "${TARGET_VM}" >/dev/null 2>&1 || true

  if [[ ${rc} -ne 0 ]]; then
    err "Functional test failed"
  fi
}
trap cleanup EXIT

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Missing required command: $1"
    exit 1
  fi
}

require_cmd lxc
require_cmd tar

if [[ ! -f "${REPO_ROOT}/scripts/lxd/${CONSUMER_TEST_SCRIPT}" ]]; then
  err "Consumer test script not found: scripts/lxd/${CONSUMER_TEST_SCRIPT}"
  exit 1
fi

wait_for_vm_agent() {
  local vm_name="$1"
  local timeout_sec="${2:-240}"
  local start_ts now_ts

  start_ts="$(date +%s)"
  while true; do
    if lxc exec "${vm_name}" -- true >/dev/null 2>&1; then
      return 0
    fi

    now_ts="$(date +%s)"
    if (( now_ts - start_ts > timeout_sec )); then
      err "Timed out waiting for VM agent in ${vm_name}"
      return 1
    fi

    sleep 2
  done
}

log "Launching VMs (${TARGET_VM}, ${CONSUMER_VM}) from ${IMAGE}"
lxc launch "${IMAGE}" "${TARGET_VM}" --vm \
  -c security.secureboot=false \
  -c limits.memory="${VM_MEMORY}" \
  -c limits.cpu="${VM_CPUS}"
lxc launch "${IMAGE}" "${CONSUMER_VM}" --vm \
  -c security.secureboot=false \
  -c limits.memory="${VM_MEMORY}" \
  -c limits.cpu="${VM_CPUS}"

log "Waiting for VM agents"
wait_for_vm_agent "${TARGET_VM}"
wait_for_vm_agent "${CONSUMER_VM}"

log "Waiting for cloud-init completion"
lxc exec "${TARGET_VM}" -- cloud-init status --wait
lxc exec "${CONSUMER_VM}" -- cloud-init status --wait

log "Configuring target VM iSCSI service"
lxc file push "${REPO_ROOT}/scripts/lxd/vm_target_setup.sh" "${TARGET_VM}/root/vm_target_setup.sh"
lxc exec "${TARGET_VM}" -- chmod +x /root/vm_target_setup.sh
lxc exec "${TARGET_VM}" -- env \
  TARGET_IQN="${TARGET_IQN}" \
  TARGET_PORT="${TARGET_PORT}" \
  ISCSI_LUN="${ISCSI_LUN}" \
  TARGET_LUN_SIZE_MB="${TARGET_LUN_SIZE_MB}" \
  bash /root/vm_target_setup.sh

TARGET_IP="$(lxc exec "${TARGET_VM}" -- bash -lc "ip -4 -o addr show dev enp5s0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")"
if [[ -z "${TARGET_IP}" ]]; then
  TARGET_IP="$(lxc exec "${TARGET_VM}" -- bash -lc "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n1")"
fi

if [[ -z "${TARGET_IP}" ]]; then
  err "Could not determine target VM IPv4 address"
  exit 1
fi

log "Target VM IP: ${TARGET_IP}"
log "Pushing apollo-fc repository into consumer VM"
lxc file push -r "${REPO_ROOT}" "${CONSUMER_VM}/root/"

lxc exec "${CONSUMER_VM}" -- chmod +x "/root/apollo-fc/scripts/lxd/${CONSUMER_TEST_SCRIPT}"

log "Running consumer VM functional validation"
lxc exec "${CONSUMER_VM}" -- env \
  TARGET_IP="${TARGET_IP}" \
  TARGET_PORT="${TARGET_PORT}" \
  TARGET_IQN="${TARGET_IQN}" \
  ISCSI_LUN="${ISCSI_LUN}" \
  FC_TARGET_WWPN="${FC_TARGET_WWPN}" \
  FC_TARGET_NODE_WWPN="${FC_TARGET_NODE_WWPN}" \
  FC_LUN_ID="${FC_LUN_ID}" \
  "/root/apollo-fc/scripts/lxd/${CONSUMER_TEST_SCRIPT}"

echo "[$(ts)] [PASS] LXD functional test complete"
