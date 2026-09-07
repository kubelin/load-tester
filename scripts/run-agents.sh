#!/bin/bash
# [마스터 머신에서 실행] 에이전트 N대에 분산 부하 실행 — jmx는 기존 것을 재사용한다.
# 각 에이전트에서 먼저 ./scripts/start-agent.sh <에이전트IP> 로 jmeter-server를 띄워둘 것.
#
# 사용법:
#   vUser 모드:  ./scripts/run-agents.sh <에이전트IP들> vusers <서버IP> <PORT> <에이전트당vUser> <THINK_MS> <DURATION>
#   고정 TPS:    ./scripts/run-agents.sh <에이전트IP들> target <서버IP> <PORT> <에이전트당TPS> <DURATION>
# 예:
#   ./scripts/run-agents.sh 10.0.0.11,10.0.0.12 vusers 10.0.0.20 18080 20000 1000 300
#     → 2대 × 20,000 = 총 40,000 vUser
#   ./scripts/run-agents.sh 10.0.0.11,10.0.0.12 target 10.0.0.20 18080 10000 300
#     → 2대 × 10,000 = 총 20,000 TPS
# ★ 수치는 "에이전트당" 값이다. 총 부하 = 값 × 에이전트 수 (실행 시작 시 총량을 출력해준다)
set -euo pipefail
cd "$(dirname "$0")/.."

AGENTS=${1:?사용법 주석 참고}
MODE=${2:?모드: vusers | target}
HOST=${3:?대상 서버 IP}
PORT=${4:-18080}

N=$(( $(echo "$AGENTS" | tr -cd ',' | wc -c) + 1 ))
ulimit -n 65536

JMAJ=$(java -version 2>&1 | awk -F'"' '/version/{split($2,v,"."); print (v[1]==1)?v[2]:v[1]}')
if [ "${JMAJ:-0}" -lt 17 ] && [ "${FORCE_JAVA:-0}" != "1" ]; then
  echo "오류: $(java -version 2>&1 | head -1) — JDK 17 필요 (DEPLOY.md 3장)"; exit 1
fi

mkdir -p results
TAG="agents_${MODE}_$(date +%m%d%H%M%S)"

case "$MODE" in
  vusers)
    PER=${5:?에이전트당 vUser 수}; THINK=${6:-1000}; DUR=${7:-300}
    RAMP=$(( PER / 100 )); [ "$RAMP" -lt 10 ] && RAMP=10
    echo "=== 분산 vUser | 에이전트 ${N}대(${AGENTS}) × ${PER}명 = 총 $(( N * PER ))명 | think ${THINK}ms | ${DUR}s ==="
    GPROPS=(-Ghost="$HOST" -Gport="$PORT" -Gthreads="$PER" -Grampup="$RAMP" -Gduration="$DUR" -Gthinkms="$THINK")
    PLAN=echo-load.jmx
    ;;
  target)
    PER=${5:?에이전트당 TPS}; DUR=${6:-300}
    TPM=$(( PER * 60 )); THREADS=$(( PER / 20 )); [ "$THREADS" -lt 100 ] && THREADS=100
    echo "=== 분산 고정TPS | 에이전트 ${N}대(${AGENTS}) × ${PER} = 총 $(( N * PER )) TPS | ${DUR}s ==="
    GPROPS=(-Ghost="$HOST" -Gport="$PORT" -Gtpm="$TPM" -Gthreads="$THREADS" -Grampup=10 -Gduration="$DUR")
    PLAN=target-tps.jmx
    ;;
  *) echo "모드는 vusers 또는 target"; exit 1 ;;
esac

# 마스터는 부하를 만들지 않으므로 힙은 결과 수집분만. 결과는 마스터에 합산 저장된다.
JVM_ARGS="-Xms1g -Xmx4g" jmeter -n -t "$PLAN" -R "$AGENTS" \
  -Dserver.rmi.ssl.disable=true \
  "${GPROPS[@]}" \
  -l "results/result_$TAG.jtl" -j "results/jmeter_$TAG.log" 2>&1 | grep -E "^summary|Remote engines|Starting|Error|error"

echo ""
echo "합산 결과(전 에이전트): ./scripts/summarize-jtl.sh results/result_$TAG.jtl <램프업초>"
echo "HTML 리포트: JVM_ARGS=-Xmx6g jmeter -g results/result_$TAG.jtl -o results/report_$TAG/"