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

# 파일 디스크립터 한도 — 하드 한도까지만 올리고, 낮으면 경고 후 계속 (하드 한도 상향은 TUNING.md 6-2 요청)
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
NOFILE=$(ulimit -n)
if [ "$NOFILE" != "unlimited" ] && [ "$NOFILE" -lt 65536 ]; then
  echo "경고: open files 한도가 $NOFILE 입니다 (권장 65536). 스레드 수가 이 값에 가까우면 'Too many open files'로 실패합니다."
  echo "      영구 상향: /etc/security/limits.d/90-loadtest.conf (TUNING.md 6-2) 적용 후 재로그인"
fi

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
TAG="target${TPS}_$(date +%m%d%H%M%S)"

echo "=== 목표 ${TPS} TPS | host=${HOST}:${PORT} threads=${THREADS} duration=${DURATION}s ==="
JVM_ARGS="-Xms2g -Xmx6g -Xss256k" jmeter -n -t "${PLAN:-target-tps.jmx}" \
  -Jhost="$HOST" -Jport="$PORT" -Jtpm="$TPM" \
  -Jthreads="$THREADS" -Jrampup="$RAMP" -Jduration="$DURATION" ${EXTRA_JOPTS:-} \
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