#!/bin/bash
# 고정 TPS 부하 실행기 — Constant Throughput Timer로 목표 TPS를 유지한다.
# 사용법: ./scripts/run-target-tps.sh <TPS> [HOST] [PORT] [DURATION초]
# 예:     ./scripts/run-target-tps.sh 10000 192.168.0.10 18080 300
set -euo pipefail
cd "$(dirname "$0")/.."

TPS=${1:?사용법: run-target-tps.sh <TPS> [HOST] [PORT] [DURATION]}
HOST=${2:-127.0.0.1}
PORT=${3:-18082}
DURATION=${4:-60}

TPM=$(( TPS * 60 ))                          # CTT 단위는 분당 샘플 수
THREADS=$(( TPS / 20 )); [ "$THREADS" -lt 100 ] && THREADS=100   # 스레드 ≥ TPS×RT + 여유
RAMP=$(( THREADS / 100 )); [ "$RAMP" -lt 5 ] && RAMP=5

ulimit -n 65536

# Java 버전 가드 — 시스템 구형 Java(1.8)가 잡히면 NoClassDefFoundError로 죽는다 (DEPLOY.md 3장)
JMAJ=$(java -version 2>&1 | awk -F'"' '/version/{split($2,v,"."); print (v[1]==1)?v[2]:v[1]}')
if [ "${JMAJ:-0}" -lt 17 ]; then
  echo "오류: $(java -version 2>&1 | head -1)"
  echo "      JMeter 5.6에는 JDK 17이 필요합니다. JAVA_HOME과 PATH 앞에 JDK17을 두세요:"
  echo "      export JAVA_HOME=~/jdk-17.x ; export PATH=\$JAVA_HOME/bin:\$PATH"
  [ "${FORCE_JAVA:-0}" != "1" ] && exit 1
fi
mkdir -p results
TAG="target${TPS}_$(date +%m%d%H%M%S)"

echo "=== 목표 ${TPS} TPS | host=${HOST}:${PORT} threads=${THREADS} duration=${DURATION}s ==="
JVM_ARGS="-Xms2g -Xmx6g -Xss256k" jmeter -n -t target-tps.jmx \
  -Jhost="$HOST" -Jport="$PORT" -Jtpm="$TPM" \
  -Jthreads="$THREADS" -Jrampup="$RAMP" -Jduration="$DURATION" \
  -l "results/result_$TAG.jtl" -j "results/jmeter_$TAG.log" 2>&1 | grep -E "^summary"

echo ""
echo "판정: 위 'summary +' 정상상태 구간이 목표 ${TPS}/s에 근접하고 Err 0%면 성공."
echo "      달성률이 크게 낮으면 → 스레드 부족(응답 느림) 또는 발생기/서버 한계. TESTING.md 참고."

# REPORT=1 이면 HTML 리포트까지 생성 (대량 샘플이면 수십 초 소요)
if [ "${REPORT:-0}" = "1" ]; then
  echo ""
  echo "HTML 리포트 생성 중... → results/report_$TAG/index.html"
  rm -rf "results/report_$TAG"
  JVM_ARGS="-Xms1g -Xmx6g" jmeter -g "results/result_$TAG.jtl" -o "results/report_$TAG" >/dev/null
else
  echo "HTML 리포트: JVM_ARGS=-Xmx6g jmeter -g results/result_$TAG.jtl -o results/report_$TAG/"
  echo "            (또는 다음부터 REPORT=1 ./scripts/run-target-tps.sh ... 로 자동 생성)"
fi