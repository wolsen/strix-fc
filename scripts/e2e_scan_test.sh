#!/usr/bin/env bash
set -euo pipefail

TARGET_A="0x500a09c0ffe10001"
TARGET_B="0x500a09c0ffe10002"
LUN_ID="1"
BACKING="${1:-/dev/loop0}"

cleanup() {
  set +e
  apollo-fcctl unmap-lun --host "${HOST_ID}" --target-wwpn "${TARGET_A}" --lun "${LUN_ID}" >/dev/null 2>&1 || true
  apollo-fcctl unmap-lun --host "${HOST_ID}" --target-wwpn "${TARGET_B}" --lun "${LUN_ID}" >/dev/null 2>&1 || true
  apollo-fcctl delete-rport --host "${HOST_ID}" --target-wwpn "${TARGET_A}" >/dev/null 2>&1 || true
  apollo-fcctl delete-rport --host "${HOST_ID}" --target-wwpn "${TARGET_B}" >/dev/null 2>&1 || true
  sudo modprobe -r apollo_fc dm_apollo_fc >/dev/null 2>&1 || true
}
trap cleanup EXIT

sudo modprobe dm_mod
sudo insmod ./src/dm_apollo_fc/dm_apollo_fc.ko
sudo insmod ./src/apollo_fc/apollo_fc.ko

HOST_BASENAME="$(basename "$(ls -1 /sys/class/fc_host | head -n1)")"
HOST_ID="${HOST_BASENAME#host}"

apollo-fcctl create-rport --host "${HOST_ID}" --target-wwpn "${TARGET_A}"
apollo-fcctl create-rport --host "${HOST_ID}" --target-wwpn "${TARGET_B}"
apollo-fcctl map-lun --host "${HOST_ID}" --target-wwpn "${TARGET_A}" --lun "${LUN_ID}" --backing "${BACKING}" --dm-name apollo_test_lun1_a
apollo-fcctl map-lun --host "${HOST_ID}" --target-wwpn "${TARGET_B}" --lun "${LUN_ID}" --backing "${BACKING}" --dm-name apollo_test_lun1_b

echo "- - -" | sudo tee "/sys/class/scsi_host/host${HOST_ID}/scan" >/dev/null

timeout 30 bash -c 'until ls /dev/disk/by-path/*-fc-0x500a09c0ffe10001-lun-1 >/dev/null 2>&1; do sleep 0.3; done'
timeout 30 bash -c 'until ls /dev/disk/by-path/*-fc-0x500a09c0ffe10002-lun-1 >/dev/null 2>&1; do sleep 0.3; done'

DEV_A="$(readlink -f /dev/disk/by-path/*-fc-0x500a09c0ffe10001-lun-1 | head -n1)"
DEV_B="$(readlink -f /dev/disk/by-path/*-fc-0x500a09c0ffe10002-lun-1 | head -n1)"

sudo dd if=/dev/zero of="${DEV_A}" bs=4096 count=8 oflag=direct conv=fsync
sudo dd if="${DEV_B}" of=/dev/null bs=4096 count=8 iflag=direct

apollo-fcctl doctor
echo "e2e_scan_test: PASS"