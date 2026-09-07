#!/bin/bash
# vUser 시나리오 실행기 — N명의 가상 유저가 think time을 두고 반복 호출한다.
# 사용법: ./scripts/run-vusers.sh <vUser수> [HOST] [PORT] [THINK_MS] [DURATION초]
# 예:     ./scripts/run-vusers.sh 5000 192.168.0.10 18080 1000 300
# 옵션:   REPORT=1  → 종료 후 HTML 리포트 자동 생성
set -euo pipefail
cd "$(dirname "$0")/.."

USERS=${1:?사용법: run-vusers.sh <vUser수> [HOST] [PORT] [THINK_MS] [DURATION]}
HOST=${2:-127.0.0.1}
PORT=${3:-18082}
THINK=${4:-1000}
DURATION=${5:-300}

RAMP=$(( USERS / 100 )); [ "$RAMP" -lt 10 ] && RAMP=10
EXPECT=$(( THINK > 0 ? USERS * 1000 / THINK : 0 ))   # 예상 TPS ≈ vUser ÷ think(초)

ulimit -n 65536
mkdir -p results
TAG="vusers${USERS}_$(date +%m%d%H%M)"

echo "=== vUser ${USERS}명 | think ${THINK}ms | ${HOST}:${PORT} | ${DURATION}s ==="
[ "$EXPECT" -gt 0 ] && echo "    예상 TPS ≈ ${EXPECT}/s (FORMULAS.md ①: vUser ÷ (RT+think))"
JVM_ARGS="-Xms2g -Xmx8g -Xss256k" jmeter -n -t echo-load.jmx \
  -Jhost="$HOST" -Jport="$PORT" -Jthreads="$USERS" -Jrampup="$RAMP" \
  -Jduration="$DURATION" -Jthinkms="$THINK" \
  -l "results/result_$TAG.jtl" -j "results/jmeter_$TAG.log" 2>&1 | grep -E "^summary"

echo ""
echo "판정: 정상상태 TPS가 예상치에 근접 + Err 0% + 응답시간 안정 → 해당 vUser 수용 가능."
if [ "${REPORT:-0}" = "1" ]; then
  echo "HTML 리포트 생성 중... → results/report_$TAG/index.html"
  jmeter -g "results/result_$TAG.jtl" -o "results/report_$TAG" >/dev/null
else
  echo "HTML 리포트: jmeter -g results/result_$TAG.jtl -o results/report_$TAG/"
fi