#!/bin/bash
# [한 발생기 박스] WebSocket 대량 연결을 N개 프로세스로 나눠 만들고 결과를 합산한다.
# Python asyncio는 프로세스당 1코어라, 다코어 박스에서 프로세스를 쪼개야 코어를 다 쓴다.
# 사용법: ./run-ws-multi.sh <총연결> <서버호스트> [포트] [경로] [간격ms] [지속s] [프로세스수]
# 예:     ./run-ws-multi.sh 20000 10.0.0.50 8080 /ws/test 1000 180 8
#         → 8개 프로세스 × 2,500연결 = 총 20,000 연결
set -uo pipefail
cd "$(dirname "$0")/.."

TOTAL=${1:?사용법: run-ws-multi.sh <총연결> <서버호스트> [포트] [경로] [간격ms] [지속s] [프로세스수]}
HOST=${2:?서버 호스트}
PORT=${3:-8080}
WPATH=${4:-/ws/test}
INTERVAL=${5:-1000}
DURATION=${6:-120}
# 프로세스 수 기본 = CPU 코어 수 (없으면 4)
PROCS=${7:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}

PER=$(( TOTAL / PROCS ))
[ "$PER" -lt 1 ] && PER=1
RAMP=$(( PER / 200 )); [ "$RAMP" -lt 5 ] && RAMP=5

command -v python3 >/dev/null || { echo "python3 없음"; exit 1; }
python3 -c "import websockets" 2>/dev/null || { echo "websockets 미설치: pip install --user 'websockets==8.1'"; exit 1; }

ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true
mkdir -p results
RUN="wsmulti_$(date +%m%d%H%M%S)"

echo "=== WS 멀티 | ${PROCS}프로세스 × ${PER}연결 = 총 $(( PER * PROCS )) | ${HOST}:${PORT}${WPATH} | 간격${INTERVAL}ms ${DURATION}s ==="
echo "    발생기 FD 한도: $(ulimit -n)  (연결당 ~164KB → $(( PER * PROCS * 164 / 1024 ))MB 예상)"

PIDS=""
for i in $(seq 1 "$PROCS"); do
  OUT="results/${RUN}_p${i}.out"
  python3 scripts/ws_loadclient.py "$PER" "$INTERVAL" "$DURATION" "$HOST" "$PORT" "$WPATH" "$RAMP" \
    > "$OUT" 2>&1 &
  PIDS="$PIDS $!"
done
echo "프로세스 ${PROCS}개 기동. 종료 대기(~$(( DURATION + RAMP + 10 ))s)..."
for p in $PIDS; do wait "$p"; done

echo ""
python3 scripts/ws_aggregate.py "$INTERVAL" results/${RUN}_p*.out