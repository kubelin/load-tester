#!/bin/bash
# 최대 TPS 탐색기 — 스레드를 단계적으로 올려 처리량 정체(plateau) 지점을 찾는다.
# 사용법: ./scripts/run-max-tps.sh [HOST] [PORT]
# 단계 구성 변경: STAGES 배열 수정 (스레드 수 목록)
set -uo pipefail
cd "$(dirname "$0")/.."

HOST=${1:-127.0.0.1}
PORT=${2:-18082}
STAGES=(${MAX_TPS_STAGES:-50 100 200 400 800})
DUR=${MAX_TPS_DUR:-45}

ulimit -n 65536
mkdir -p results
RUN="max_$(date +%m%d%H%M)"
declare -a RESULTS

echo "=== 최대 TPS 탐색 | host=${HOST}:${PORT} 단계=${STAGES[*]} 각 ${DUR}s ==="
for T in "${STAGES[@]}"; do
  TAG="${RUN}_t${T}"
  RAMP=5
  echo ""
  echo "--- ${T} threads ---"
  JVM_ARGS="-Xms2g -Xmx6g -Xss256k" jmeter -n -t echo-load.jmx \
    -Jhost="$HOST" -Jport="$PORT" -Jthreads="$T" -Jrampup="$RAMP" \
    -Jduration="$DUR" -Jthinkms=0 \
    -l "results/result_$TAG.jtl" -j "results/jmeter_$TAG.log" 2>&1 | grep -E "^summary" | tail -3
  # 정상상태 TPS = 'summary +' 구간들 중 최대값 (램프업/종료 구간 왜곡 배제)
  RATE=$(grep "summary +" "results/jmeter_$TAG.log" 2>/dev/null \
    | grep -oE '= *[0-9.]+/s' | grep -oE '[0-9.]+' | sort -rn | head -1)
  RESULTS+=("${T} threads → ${RATE:-?}/s")
  sleep 5
done

echo ""
echo "===== 단계별 결과 ====="
printf '%s\n' "${RESULTS[@]}"
echo ""
echo "판정: 스레드를 늘려도 TPS가 더 안 오르는(또는 떨어지는) 지점 직전이 최대 TPS."
echo "      에러가 발생하기 시작한 단계는 이미 한계 초과. 상세는 results/의 jtl 참고."

# REPORT=1 이면 단계별 HTML 리포트 생성 (단계별 부하 조건이 달라 병합하지 않는다)
if [ "${REPORT:-0}" = "1" ]; then
  echo ""
  for T in "${STAGES[@]}"; do
    TAG="${RUN}_t${T}"
    echo "HTML 리포트 생성: results/report_$TAG/index.html"
    jmeter -g "results/result_$TAG.jtl" -o "results/report_$TAG" >/dev/null 2>&1 \
      || echo "  (생성 실패 — results/result_$TAG.jtl 확인)"
  done
else
  echo ""
  echo "HTML 리포트(단계별): jmeter -g results/result_${RUN}_t<스레드>.jtl -o results/report_t<스레드>/"
  echo "                   (또는 REPORT=1 ./scripts/run-max-tps.sh ... 로 전 단계 자동 생성)"
fi