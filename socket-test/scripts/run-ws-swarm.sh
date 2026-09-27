#!/bin/bash
# [여러 발생기 호스트] WebSocket 연결을 여러 발생기에서 동시에 맺어 서버 실한계를 찾는다.
# 서버는 여러 소스 IP에서 연결을 받게 되고(현실적), 발생기 1대의 포트/CPU 한계를 우회한다.
# 전제: 각 발생기 호스트에 SSH 키 접속 가능 + python3+websockets 설치 + 이 레포가 같은 경로에 있을 것.
#
# 사용법: ./run-ws-swarm.sh "<user@host1,user@host2,...>" <총연결> <서버호스트> [포트] [경로] [간격ms] [지속s]
# 예:     ./run-ws-swarm.sh "load@10.0.0.11,load@10.0.0.12,load@10.0.0.13" 60000 10.0.0.50 8080 /ws/test 1000 180
#         → 3개 발생기 × 20,000 = 총 60,000 연결이 서버에 3개 IP에서 들어감
set -uo pipefail
cd "$(dirname "$0")/.."

HOSTS_CSV=${1:?"발생기 목록 (user@host 콤마구분)"}
TOTAL=${2:?총 연결수}
TARGET=${3:?서버 호스트}
PORT=${4:-8080}
WPATH=${5:-/ws/test}
INTERVAL=${6:-1000}
DURATION=${7:-120}
# 발생기에서 이 레포가 있는 경로 (기본: 현재와 동일 경로). 다르면 REMOTE_DIR로 지정.
REMOTE_DIR=${REMOTE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}

IFS=',' read -r -a HOSTS <<< "$HOSTS_CSV"
N=${#HOSTS[@]}
PER=$(( TOTAL / N ))
RAMP=$(( PER / 200 )); [ "$RAMP" -lt 5 ] && RAMP=5
RUN="wsswarm_$(date +%m%d%H%M%S)"
mkdir -p results

echo "=== WS 스웜 | 발생기 ${N}대 × ${PER}연결 = 총 $(( PER * N )) | 타겟 ${TARGET}:${PORT}${WPATH} | 간격${INTERVAL}ms ${DURATION}s ==="

# 각 발생기에서 ws_loadclient 를 백그라운드로 기동 (SSH). stdout 을 원격 파일로.
for h in "${HOSTS[@]}"; do
  echo "  → $h 기동 (${PER}연결)"
  ssh -o StrictHostKeyChecking=accept-new "$h" \
    "cd '$REMOTE_DIR/socket-test' && ulimit -n 1048576 2>/dev/null; \
     nohup python3 scripts/ws_loadclient.py $PER $INTERVAL $DURATION $TARGET $PORT $WPATH $RAMP \
     > /tmp/${RUN}.out 2>&1 & echo started" \
    || echo "    [경고] $h 기동 실패 — SSH/경로/의존성 확인"
done

WAIT=$(( DURATION + RAMP + 15 ))
echo "전 발생기 실행 중. 종료 대기 ~${WAIT}s..."
# 폴링 없이 넉넉히 대기 (원격 백그라운드라 로컬에서 wait 불가)
END=$(( $(date +%s) + WAIT ))
while [ "$(date +%s)" -lt "$END" ]; do sleep 10; done

# 결과 회수
echo "결과 회수..."
i=0
for h in "${HOSTS[@]}"; do
  i=$(( i + 1 ))
  scp -o StrictHostKeyChecking=accept-new "$h:/tmp/${RUN}.out" "results/${RUN}_h${i}.out" 2>/dev/null \
    || echo "  [경고] $h 결과 회수 실패"
done

echo ""
python3 scripts/ws_aggregate.py "$INTERVAL" results/${RUN}_h*.out 2>/dev/null \
  || echo "합산할 결과 파일이 없음 — 발생기 실행/회수 확인"