#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 /dev/<backing>"
  exit 1
fi

BACKING="$1"
HOST_ID="${HOST_ID:-0}"
TARGET_A="0x500a09c0ffe1000a"
TARGET_B="0x500a09c0ffe1000b"
LUN="10"

apollo-fcctl create-rport --host "${HOST_ID}" --target-wwpn "${TARGET_A}"
apollo-fcctl create-rport --host "${HOST_ID}" --target-wwpn "${TARGET_B}"

apollo-fcctl map-lun --host "${HOST_ID}" --target-wwpn "${TARGET_A}" --lun "${LUN}" --backing "${BACKING}" --dm-name apollo_dual_a
apollo-fcctl map-lun --host "${HOST_ID}" --target-wwpn "${TARGET_B}" --lun "${LUN}" --backing "${BACKING}" --dm-name apollo_dual_b

echo "- - -" | sudo tee "/sys/class/scsi_host/host${HOST_ID}/scan" >/dev/null
sleep 1

ls -l /dev/disk/by-path/*-fc-0x500a09c0ffe1000a-lun-10
ls -l /dev/disk/by-path/*-fc-0x500a09c0ffe1000b-lun-10

apollo-fcctl list --json