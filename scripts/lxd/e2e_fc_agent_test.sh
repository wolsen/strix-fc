#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Canonical, Ltd.
# SPDX-License-Identifier: GPL-2.0-only
#
# E2E test: Strix FC Agent ↔ Apollo Gateway
#
# Uses the existing functional_test_lxd.sh framework with:
#   - vm_target_gateway_setup.sh  (target VM: iSCSI + gateway)
#   - vm_consumer_agent_test.sh   (consumer VM: agent + validation)
#
# The Apollo Gateway source tree must be available alongside this repo.
# Expected layout:
#   parent/
#     strix-fc/       ← this repo
#     apollo-gateway/  ← gateway repo
#
# Usage:
#   ./scripts/lxd/e2e_fc_agent_test.sh [--destroy-on-success] [--name-prefix PREFIX]
set -euo pipefail

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [E2E-AGENT][INFO] $*"; }
err() { echo "[$(ts)] [E2E-AGENT][ERROR] $*" >&2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATEWAY_ROOT="${APOLLO_GATEWAY_ROOT:-$(cd "${REPO_ROOT}/../apollo-gateway" 2>/dev/null && pwd || echo "")}"

NAME_PREFIX="${NAME_PREFIX:-e2e-agent}"
DESTROY_ON_SUCCESS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destroy-on-success) DESTROY_ON_SUCCESS=1; shift ;;
    --name-prefix) NAME_PREFIX="$2"; shift 2 ;;
    *) err "Unknown arg: $1"; exit 1 ;;
  esac
done

TARGET_VM="${NAME_PREFIX}-target"
CONSUMER_VM="${NAME_PREFIX}-consumer"
IMAGE="${LXD_IMAGE:-ubuntu:24.04}"
KEEP_VMS="${KEEP_VMS:-0}"
VM_MEMORY="${VM_MEMORY:-4GiB}"
VM_CPUS="${VM_CPUS:-2}"

TARGET_IQN="${TARGET_IQN:-iqn.2026-03.com.lunacy:apollo.fc.agent.test}"
TARGET_PORT="${TARGET_PORT:-3260}"
ISCSI_LUN="${ISCSI_LUN:-1}"
TARGET_LUN_SIZE_MB="${TARGET_LUN_SIZE_MB:-512}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"

FC_TARGET_WWPN="${FC_TARGET_WWPN:-0x500a09c0ffe1aa01}"
FC_TARGET_NODE_WWPN="${FC_TARGET_NODE_WWPN:-0x500a09c0ffe1bb01}"
FC_LUN_ID="${FC_LUN_ID:-0}"

# --- Validation ---
if [[ -z "${GATEWAY_ROOT}" || ! -d "${GATEWAY_ROOT}" ]]; then
  err "Apollo Gateway source not found."
  err "Set APOLLO_GATEWAY_ROOT or place it at ${REPO_ROOT}/../apollo-gateway"
  exit 1
fi
log "Using apollo-gateway at: ${GATEWAY_ROOT}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Missing required command: $1"
    exit 1
  fi
}
require_cmd lxc

cleanup() {
  local rc=$?
  if [[ "${KEEP_VMS}" == "1" ]]; then
    log "KEEP_VMS=1, leaving VMs: ${TARGET_VM}, ${CONSUMER_VM}"
    return
  fi
  if [[ ${rc} -eq 0 && ${DESTROY_ON_SUCCESS} -eq 1 ]]; then
    log "Destroying VMs (test passed)"
    lxc delete -f "${CONSUMER_VM}" >/dev/null 2>&1 || true
    lxc delete -f "${TARGET_VM}" >/dev/null 2>&1 || true
  elif [[ ${rc} -ne 0 ]]; then
    err "Test FAILED — leaving VMs for debugging: ${TARGET_VM}, ${CONSUMER_VM}"
  fi
}
trap cleanup EXIT

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

# --- Launch VMs ---
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

# --- Push sources into VMs ---
log "Packaging repositories (excluding .venv/.git/__pycache__)"
FC_ARCHIVE="/tmp/strix-fc-e2e.tgz"
GW_ARCHIVE="/tmp/apollo-gateway-e2e.tgz"

tar -C "$(dirname "${REPO_ROOT}")" \
  --exclude='strix-fc/.venv' \
  --exclude='strix-fc/.git' \
  --exclude='strix-fc/**/__pycache__' \
  --exclude='strix-fc/.pytest_cache' \
  --exclude='strix-fc/build' \
  --exclude='strix-fc/dist' \
  -czf "${FC_ARCHIVE}" "$(basename "${REPO_ROOT}")"

tar -C "$(dirname "${GATEWAY_ROOT}")" \
  --exclude='apollo-gateway/.venv' \
  --exclude='apollo-gateway/.git' \
  --exclude='apollo-gateway/**/__pycache__' \
  --exclude='apollo-gateway/.pytest_cache' \
  --exclude='apollo-gateway/build' \
  --exclude='apollo-gateway/dist' \
  -czf "${GW_ARCHIVE}" "$(basename "${GATEWAY_ROOT}")"

log "Pushing strix-fc archive into target + consumer VMs"
lxc file push "${FC_ARCHIVE}" "${TARGET_VM}/root/strix-fc-e2e.tgz"
lxc file push "${FC_ARCHIVE}" "${CONSUMER_VM}/root/strix-fc-e2e.tgz"

log "Pushing apollo-gateway archive into target VM"
lxc file push "${GW_ARCHIVE}" "${TARGET_VM}/root/apollo-gateway-e2e.tgz"

log "Extracting repositories inside VMs"
lxc exec "${TARGET_VM}" -- bash -lc "cd /root && tar -xzf strix-fc-e2e.tgz && tar -xzf apollo-gateway-e2e.tgz"
lxc exec "${CONSUMER_VM}" -- bash -lc "cd /root && tar -xzf strix-fc-e2e.tgz"

rm -f "${FC_ARCHIVE}" "${GW_ARCHIVE}"

# --- Target VM: iSCSI + Gateway ---
log "Running target+gateway setup"
lxc file push "${REPO_ROOT}/scripts/lxd/vm_target_gateway_setup.sh" "${TARGET_VM}/root/vm_target_gateway_setup.sh"
lxc exec "${TARGET_VM}" -- chmod +x /root/vm_target_gateway_setup.sh
lxc exec "${TARGET_VM}" -- env \
  TARGET_IQN="${TARGET_IQN}" \
  TARGET_PORT="${TARGET_PORT}" \
  ISCSI_LUN="${ISCSI_LUN}" \
  TARGET_LUN_SIZE_MB="${TARGET_LUN_SIZE_MB}" \
  GATEWAY_PORT="${GATEWAY_PORT}" \
  bash /root/vm_target_gateway_setup.sh

TARGET_IP="$(lxc exec "${TARGET_VM}" -- bash -lc "ip -4 -o addr show dev enp5s0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")"
if [[ -z "${TARGET_IP}" ]]; then
  TARGET_IP="$(lxc exec "${TARGET_VM}" -- bash -lc "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n1")"
fi
if [[ -z "${TARGET_IP}" ]]; then
  err "Could not determine target VM IP"
  exit 1
fi
log "Target VM IP: ${TARGET_IP}"

# --- Consumer VM: agent test ---
log "Running consumer agent test"
lxc file push "${REPO_ROOT}/scripts/lxd/vm_consumer_agent_test.sh" "${CONSUMER_VM}/root/vm_consumer_agent_test.sh"
lxc exec "${CONSUMER_VM}" -- chmod +x /root/vm_consumer_agent_test.sh
lxc exec "${CONSUMER_VM}" -- env \
  TARGET_IP="${TARGET_IP}" \
  GATEWAY_PORT="${GATEWAY_PORT}" \
  TARGET_IQN="${TARGET_IQN}" \
  TARGET_PORT="${TARGET_PORT}" \
  ISCSI_LUN="${ISCSI_LUN}" \
  FC_TARGET_WWPN="${FC_TARGET_WWPN}" \
  FC_TARGET_NODE_WWPN="${FC_TARGET_NODE_WWPN}" \
  FC_LUN_ID="${FC_LUN_ID}" \
  bash /root/vm_consumer_agent_test.sh

echo "[$(ts)] [PASS] E2E FC Agent test complete"
