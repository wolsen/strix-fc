#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Canonical, Ltd.
# SPDX-License-Identifier: GPL-2.0-only
#
# Target VM setup: iSCSI target + Strix Gateway
#
# This script runs INSIDE the target VM. It configures:
# 1. An iSCSI target (via targetcli-fb) with a backing fileio LUN.
# 2. Strix Gateway (the control-plane REST API) on port 8080.
#
# Environment variables (defaults shown):
#   TARGET_IQN           iqn.2026-03.com.lunacy:apollo.fc.agent.test
#   TARGET_PORT          3260
#   ISCSI_LUN            1
#   TARGET_LUN_SIZE_MB   512
#   GATEWAY_PORT         8080
set -euo pipefail

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [TARGET-GW][INFO] $*"; }
err() { echo "[$(ts)] [TARGET-GW][ERROR] $*" >&2; }

TARGET_IQN="${TARGET_IQN:-iqn.2026-03.com.lunacy:strix.fc.agent.test}"
TARGET_PORT="${TARGET_PORT:-3260}"
ISCSI_LUN="${ISCSI_LUN:-1}"
TARGET_LUN_SIZE_MB="${TARGET_LUN_SIZE_MB:-512}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
BACKING_FILE="/var/lib/strix-fc/target-lun.img"
BACKSTORE_NAME="strix_fc_lun"
SPDK_SOCK="/var/tmp/spdk.sock"

export DEBIAN_FRONTEND=noninteractive

# --- iSCSI target ---
log "Installing dependencies"
apt-get update
apt-get install -y targetcli-fb python3 python3-venv curl ca-certificates

log "Loading target kernel modules"
modprobe target_core_mod
modprobe iscsi_target_mod

log "Preparing backing image ${BACKING_FILE}"
mkdir -p /var/lib/strix-fc
truncate -s "${TARGET_LUN_SIZE_MB}M" "${BACKING_FILE}"

log "Configuring iSCSI target via targetcli"
targetcli clearconfig confirm=True
targetcli /backstores/fileio create "${BACKSTORE_NAME}" "${BACKING_FILE}" "${TARGET_LUN_SIZE_MB}M" write_back=false
targetcli /iscsi create "${TARGET_IQN}"
targetcli "/iscsi/${TARGET_IQN}/tpg1/portals" create 0.0.0.0 "${TARGET_PORT}" >/dev/null 2>&1 || true
targetcli "/iscsi/${TARGET_IQN}/tpg1/luns" create "/backstores/fileio/${BACKSTORE_NAME}" "${ISCSI_LUN}"
targetcli "/iscsi/${TARGET_IQN}/tpg1" set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1 demo_mode_discovery=1
targetcli saveconfig

if ! ss -lnt | grep -q ":${TARGET_PORT} "; then
  err "iSCSI target portal not listening on port ${TARGET_PORT}"
  exit 1
fi
log "iSCSI target ready: iqn=${TARGET_IQN} port=${TARGET_PORT}"

# --- Strix Gateway ---
GATEWAY_ROOT="/root/strix-gateway"
if [[ ! -d "${GATEWAY_ROOT}" ]]; then
  err "Strix Gateway source not found at ${GATEWAY_ROOT}"
  exit 1
fi

log "Installing Strix Gateway"
cd "${GATEWAY_ROOT}"

# Ensure schema is created fresh for this E2E run.
rm -f strix_gateway.db

if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
fi

uv venv --clear .venv
uv pip install --python .venv/bin/python -e .

log "Starting fake SPDK JSON-RPC socket at ${SPDK_SOCK}"
cat > /usr/local/bin/strix-fake-spdk.py <<'PY'
#!/usr/bin/env python3
import json
import os
import socket
import threading


SOCK = "/var/tmp/spdk.sock"

state = {
  "bdevs": {},
  "lvstores": set(),
  "portal_groups": [],
  "initiator_groups": [],
  "targets": {},
  "nvmf_transports": [],
  "nvmf_subsystems": {},
}

lock = threading.Lock()


def _ok(result, req_id):
  return {"jsonrpc": "2.0", "id": req_id, "result": result}


def _err(code, message, req_id):
  return {
    "jsonrpc": "2.0",
    "id": req_id,
    "error": {"code": code, "message": message},
  }


def _bdev_list(name=None):
  if name:
    bdev = state["bdevs"].get(name)
    return [bdev] if bdev else []
  return list(state["bdevs"].values())


def handle(method, params):
  if method == "bdev_get_bdevs":
    return _bdev_list(params.get("name") if params else None)

  if method == "bdev_malloc_create":
    name = params["name"]
    num_blocks = int(params.get("num_blocks", 0))
    block_size = int(params.get("block_size", 512))
    with lock:
      state["bdevs"][name] = {
        "name": name,
        "num_blocks": num_blocks,
        "block_size": block_size,
      }
    return name

  if method == "bdev_aio_create":
    name = params["name"]
    filename = params["filename"]
    block_size = int(params.get("block_size", 512))
    size = os.path.getsize(filename) if os.path.exists(filename) else 0
    num_blocks = size // block_size if block_size else 0
    with lock:
      state["bdevs"][name] = {
        "name": name,
        "filename": filename,
        "num_blocks": num_blocks,
        "block_size": block_size,
      }
    return name

  if method == "bdev_lvol_get_lvstores":
    lvs_name = params.get("lvs_name") if params else None
    if lvs_name:
      return [{"name": lvs_name}] if lvs_name in state["lvstores"] else []
    return [{"name": name} for name in sorted(state["lvstores"])]

  if method == "bdev_lvol_create_lvstore":
    lvs_name = params["lvs_name"]
    with lock:
      state["lvstores"].add(lvs_name)
    return lvs_name

  if method == "bdev_lvol_create":
    lvs_name = params["lvs_name"]
    lvol_name = params["lvol_name"]
    size_in_mib = int(params.get("size_in_mib", 0))
    full_name = f"{lvs_name}/{lvol_name}"
    with lock:
      state["bdevs"][full_name] = {
        "name": full_name,
        "num_blocks": size_in_mib * 2048,
        "block_size": 512,
      }
    return full_name

  if method == "iscsi_get_portal_groups":
    return state["portal_groups"]

  if method == "iscsi_create_portal_group":
    with lock:
      state["portal_groups"].append(
        {"tag": params["tag"], "portals": params.get("portals", [])}
      )
    return True

  if method == "iscsi_get_initiator_groups":
    return state["initiator_groups"]

  if method == "iscsi_create_initiator_group":
    with lock:
      state["initiator_groups"].append(
        {
          "tag": params["tag"],
          "initiators": params.get("initiators", []),
          "netmasks": params.get("netmasks", []),
        }
      )
    return True

  if method == "iscsi_get_target_nodes":
    return list(state["targets"].values())

  if method == "iscsi_create_target_node":
    name = params["name"]
    with lock:
      state["targets"][name] = {
        "name": name,
        "luns": [
          {
            "lun_id": int(lun.get("lun_id", 0)),
            "bdev_name": lun.get("bdev_name"),
          }
          for lun in params.get("luns", [])
        ],
      }
    return True

  if method == "iscsi_target_node_add_lun":
    name = params["name"]
    target = state["targets"].setdefault(name, {"name": name, "luns": []})
    target["luns"].append(
      {
        "lun_id": int(params.get("lun_id", 0)),
        "bdev_name": params.get("bdev_name"),
      }
    )
    return True

  if method == "iscsi_delete_target_node":
    state["targets"].pop(params.get("name", ""), None)
    return True

  if method == "nvmf_get_transports":
    return state["nvmf_transports"]

  if method == "nvmf_create_transport":
    state["nvmf_transports"].append(params or {})
    return True

  if method == "nvmf_get_subsystems":
    nqn = params.get("nqn") if params else None
    if nqn:
      ss = state["nvmf_subsystems"].get(nqn)
      return [ss] if ss else []
    return list(state["nvmf_subsystems"].values())

  if method == "nvmf_create_subsystem":
    nqn = params["nqn"]
    state["nvmf_subsystems"][nqn] = {
      "nqn": nqn,
      "listen_addresses": [],
      "namespaces": [],
    }
    return True

  if method == "nvmf_subsystem_add_listener":
    nqn = params["nqn"]
    ss = state["nvmf_subsystems"].setdefault(
      nqn, {"nqn": nqn, "listen_addresses": [], "namespaces": []}
    )
    ss["listen_addresses"].append(params.get("listen_address", {}))
    return True

  if method == "nvmf_subsystem_add_ns":
    nqn = params["nqn"]
    ss = state["nvmf_subsystems"].setdefault(
      nqn, {"nqn": nqn, "listen_addresses": [], "namespaces": []}
    )
    nsid = int(params.get("nsid", 1))
    ss["namespaces"].append({"nsid": nsid, "bdev_name": params.get("namespace", {}).get("bdev_name")})
    return nsid

  if method == "nvmf_subsystem_remove_ns":
    nqn = params["nqn"]
    nsid = int(params.get("nsid", 0))
    ss = state["nvmf_subsystems"].get(nqn)
    if ss:
      ss["namespaces"] = [ns for ns in ss.get("namespaces", []) if int(ns.get("nsid", -1)) != nsid]
    return True

  if method == "bdev_lvol_delete":
    name = params.get("name")
    state["bdevs"].pop(name, None)
    return True

  if method == "bdev_lvol_resize":
    return True

  return True


def serve():
  if os.path.exists(SOCK):
    os.unlink(SOCK)

  server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  server.bind(SOCK)
  os.chmod(SOCK, 0o777)
  server.listen(64)

  while True:
    conn, _ = server.accept()
    with conn:
      raw = b""
      while True:
        chunk = conn.recv(65536)
        if not chunk:
          break
        raw += chunk
        try:
          req = json.loads(raw.decode())
          break
        except json.JSONDecodeError:
          continue
      if not raw:
        continue

      req_id = req.get("id")
      method = req.get("method", "")
      params = req.get("params", {})

      try:
        result = handle(method, params)
        resp = _ok(result, req_id)
      except Exception as exc:
        resp = _err(-32000, str(exc), req_id)

      conn.sendall(json.dumps(resp).encode())


if __name__ == "__main__":
  serve()
PY
chmod +x /usr/local/bin/strix-fake-spdk.py
nohup /usr/local/bin/strix-fake-spdk.py > /var/log/strix-fake-spdk.log 2>&1 &

log "Starting Strix Gateway on port ${GATEWAY_PORT} (background)"
nohup .venv/bin/uvicorn strix_gateway.main:app \
  --host 0.0.0.0 --port "${GATEWAY_PORT}" \
  --log-level info \
  > /var/log/strix-gateway.log 2>&1 &
GW_PID=$!

# Wait for gateway to become ready
log "Waiting for Gateway to become ready"
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${GATEWAY_PORT}/healthz" >/dev/null 2>&1; then
    log "Gateway ready (pid=${GW_PID})"
    break
  fi
  if [[ $i -eq 30 ]]; then
    err "Gateway failed to start within 30s"
    cat /var/log/strix-gateway.log
    exit 1
  fi
  sleep 1
done

log "Target+Gateway VM setup complete"
