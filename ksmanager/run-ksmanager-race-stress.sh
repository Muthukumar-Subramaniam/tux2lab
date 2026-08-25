#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
HARNESS="${SCRIPT_DIR}/run-ksmanager-dev-tests.sh"

if [[ ! -x "${HARNESS}" ]]; then
  echo "[FAIL] Missing executable harness: ${HARNESS}"
  exit 1
fi

ITERATIONS=${ITERATIONS:-25}
PARALLEL_WORKERS=${PARALLEL_WORKERS:-1}
STOP_ON_FAIL=${STOP_ON_FAIL:-1}

PASS=0
FAIL=0

usage() {
  cat <<'EOF'
Usage: run-ksmanager-race-stress.sh [--iterations N] [--parallel N] [--continue-on-fail]

Env vars (optional):
  ITERATIONS       Total runs per worker (default: 25)
  PARALLEL_WORKERS Number of workers in parallel (default: 1)
  STOP_ON_FAIL     1=stop early, 0=continue (default: 1)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)
      ITERATIONS="$2"
      shift 2
      ;;
    --parallel)
      PARALLEL_WORKERS="$2"
      shift 2
      ;;
    --continue-on-fail)
      STOP_ON_FAIL=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[FAIL] Unknown arg: $1"
      usage
      exit 1
      ;;
  esac
done

if ! [[ "${ITERATIONS}" =~ ^[0-9]+$ ]] || [[ "${ITERATIONS}" -le 0 ]]; then
  echo "[FAIL] ITERATIONS must be a positive integer"
  exit 1
fi
if ! [[ "${PARALLEL_WORKERS}" =~ ^[0-9]+$ ]] || [[ "${PARALLEL_WORKERS}" -le 0 ]]; then
  echo "[FAIL] PARALLEL_WORKERS must be a positive integer"
  exit 1
fi

LOG_ROOT=$(mktemp -d /tmp/ksmanager-race-stress.XXXXXX)
trap 'rm -rf "${LOG_ROOT}"' EXIT

echo "[INFO] Stress run start"
echo "[INFO] iterations=${ITERATIONS} parallel_workers=${PARALLEL_WORKERS} stop_on_fail=${STOP_ON_FAIL}"
echo "[INFO] logs=${LOG_ROOT}"

run_worker() {
  local worker_id="$1"
  local i=1
  local worker_fail=0
  local log_file

  while [[ ${i} -le ${ITERATIONS} ]]; do
    log_file="${LOG_ROOT}/worker-${worker_id}-iter-${i}.log"
    if bash "${HARNESS}" >"${log_file}" 2>&1; then
      echo "[PASS] worker=${worker_id} iter=${i}"
    else
      echo "[FAIL] worker=${worker_id} iter=${i} (log: ${log_file})"
      worker_fail=1
      if [[ ${STOP_ON_FAIL} -eq 1 ]]; then
        return 1
      fi
    fi
    i=$((i + 1))
  done

  return ${worker_fail}
}

if [[ ${PARALLEL_WORKERS} -eq 1 ]]; then
  if run_worker 1; then
    PASS=${ITERATIONS}
  else
    FAIL=1
  fi
else
  pids=()
  for w in $(seq 1 "${PARALLEL_WORKERS}"); do
    run_worker "${w}" &
    pids+=("$!")
  done

  for p in "${pids[@]}"; do
    if ! wait "${p}"; then
      FAIL=$((FAIL + 1))
    fi
  done
fi

if [[ ${PARALLEL_WORKERS} -eq 1 ]]; then
  if [[ ${FAIL} -eq 0 ]]; then
    echo "[OK] Stress run passed"
    exit 0
  fi
  echo "[FAIL] Stress run failed"
  exit 1
fi

if [[ ${FAIL} -eq 0 ]]; then
  echo "[OK] Stress run passed across ${PARALLEL_WORKERS} workers"
  exit 0
fi

echo "[FAIL] ${FAIL}/${PARALLEL_WORKERS} workers reported failures"
exit 1
