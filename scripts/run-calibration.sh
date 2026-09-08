#!/bin/bash
# 원격 캘리브레이션 — 발생기+환경의 최대 발생 능력을 실측하고 목표 대비 합격 여부를 판정한다.
# 본 테스트 전 필수 (DEPLOY.md 4장). 대상 서버(dummy-json)가 이미 떠 있어야 한다.
# 사용법: ./scripts/run-calibration.sh <서버IP> [PORT] [목표TPS]
# 예:     ./scripts/run-calibration.sh 192.168.0.10 18080 10000
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${1:?사용법: run-calibration.sh <서버IP> [PORT] [목표TPS]}
PORT=${2:-18080}
TARGET=${3:-0}
DUR=${CALIB_DUR:-60}

ulimit -n 65536

# Java 버전 가드 — 시스템 구형 Java(1.8)가 잡히면 NoClassDefFoundError로 죽는다 (DEPLOY.md 3장)
JBIN=java; [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] && JBIN="$JAVA_HOME/bin/java"
JMAJ=$("$JBIN" -version 2>&1 | awk -F'"' '/version/{split($2,v,"."); print (v[1]==1)?v[2]:v[1]}')
if [ "${JMAJ:-0}" -lt 17 ]; then
  echo "오류: $("$JBIN" -version 2>&1 | head -1)"
  echo "      JMeter 5.6에는 JDK 17이 필요합니다. JAVA_HOME과 PATH 앞에 JDK17을 두세요:"
  echo "      export JAVA_HOME=~/jdk-17.x ; export PATH=\$JAVA_HOME/bin:\$PATH"
  [ "${FORCE_JAVA:-0}" != "1" ] && exit 1
fi
mkdir -p results
TAG="calib_$(date +%m%d%H%M%S)"

echo "=== 캘리브레이션 | ${HOST}:${PORT} | 200스레드 무휴식 ${DUR}s ==="
curl -sf -m 3 "http://${HOST}:${PORT}/health" >/dev/null \
  || { echo "서버 응답 없음 — 배포/방화벽 확인 (DEPLOY.md 2·3장)"; exit 1; }

JVM_ARGS="-Xms2g -Xmx6g -Xss256k" jmeter -n -t "${PLAN:-echo-load.jmx}" \
  -Jhost="$HOST" -Jport="$PORT" -Jthreads=200 -Jrampup=5 \
  -Jduration="$DUR" -Jthinkms=0 ${EXTRA_JOPTS:-} \
  -l "results/result_$TAG.jtl" -j "results/jmeter_$TAG.log" 2>&1 | grep -E "^summary"

# 정상상태 TPS = 'summary +' 구간 최대값 (짧은 실행이라 중간행이 없으면 'summary =' 전체 평균 사용)
RATE=$(grep "summary +" "results/jmeter_$TAG.log" 2>/dev/null \
  | grep -oE '= *[0-9.]+/s' | grep -oE '[0-9.]+' | sort -rn | head -1 || true)
[ -z "$RATE" ] && RATE=$(grep "summary =" "results/jmeter_$TAG.log" 2>/dev/null \
  | tail -1 | grep -oE '= *[0-9.]+/s' | grep -oE '[0-9.]+' || true)
ERR=$(grep "summary =" "results/jmeter_$TAG.log" 2>/dev/null \
  | tail -1 | grep -oE '\([0-9.]+%\)' | tr -d '(%)' || true)
RATE=${RATE%%.*}   # 정수화 (판정 비교용)

echo ""
echo "===== 캘리브레이션 결과 ====="
echo "발생 능력(정상상태 최대): ${RATE:-측정실패}/s  |  에러율: ${ERR:-?}%"
if [ "$TARGET" -gt 0 ] && [ -n "${RATE:-}" ]; then
  NEED=$(( TARGET * 13 / 10 ))
  OK=$(awk -v r="$RATE" -v n="$NEED" 'BEGIN{print (r>=n)?"y":"n"}')
  if [ "$OK" = y ]; then
    echo "판정: 합격 — 목표 ${TARGET} TPS의 1.3배(${NEED}) 이상. 본 테스트 진행 가능"
  else
    echo "판정: 불합격 — 목표 ${TARGET} TPS 검증에는 ${NEED}/s 이상 필요"
    echo "      원인 후보: 발생기 CPU(top의 %st 포함), 커널 설정(check-kernel-loadgen.sh), 네트워크"
  fi
else
  echo "판정 기준: 이 수치가 본 테스트 목표 TPS의 1.3배 이상이어야 측정이 유효하다"
fi