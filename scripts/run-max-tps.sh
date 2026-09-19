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

# Java 버전 가드 — JMeter 5.6.3은 Java 8 이상 (8u432·21 실측). 1.8인데 NoClassDefFoundError가 나면
# headless JRE일 가능성이 크니 전체 JDK 8을 쓴다 (DEPLOY.md 3장). FORCE_JAVA=1 로 가드 무시.
JBIN=java; [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] && JBIN="$JAVA_HOME/bin/java"
JMAJ=$("$JBIN" -version 2>&1 | awk -F'"' '/version/{split($2,v,"."); print (v[1]==1)?v[2]:v[1]}')
if [ "${JMAJ:-0}" -lt 8 ]; then
  echo "오류: $("$JBIN" -version 2>&1 | head -1)"
  echo "      JMeter 5.6.3에는 Java 8 이상이 필요합니다. JAVA_HOME과 PATH 앞에 JDK를 두세요:"
  echo "      export JAVA_HOME=<jdk 경로> ; export PATH=\$JAVA_HOME/bin:\$PATH"
  [ "${FORCE_JAVA:-0}" != "1" ] && exit 1
fi
mkdir -p results
RUN="max_$(date +%m%d%H%M%S)"
declare -a RESULTS

echo "=== 최대 TPS 탐색 | host=${HOST}:${PORT} 단계=${STAGES[*]} 각 ${DUR}s ==="
for T in "${STAGES[@]}"; do
  TAG="${RUN}_t${T}"
  RAMP=5
  echo ""
  echo "--- ${T} threads ---"
  JVM_ARGS="-Xms2g -Xmx6g -Xss256k" jmeter -n -t "${PLAN:-echo-load.jmx}" \
    -Jhost="$HOST" -Jport="$PORT" -Jthreads="$T" -Jrampup="$RAMP" \
    -Jduration="$DUR" -Jthinkms=0 ${EXTRA_JOPTS:-} \
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
    rm -rf "results/report_$TAG"
    JVM_ARGS="-Xms1g -Xmx6g" jmeter -g "results/result_$TAG.jtl" -o "results/report_$TAG" >/dev/null 2>&1 \
      || echo "  (생성 실패 — results/result_$TAG.jtl 확인)"
  done
else
  echo ""
  echo "HTML 리포트(단계별): JVM_ARGS=-Xmx6g jmeter -g results/result_${RUN}_t<스레드>.jtl -o results/report_t<스레드>/"
  echo "                   (또는 REPORT=1 ./scripts/run-max-tps.sh ... 로 전 단계 자동 생성)"
fi