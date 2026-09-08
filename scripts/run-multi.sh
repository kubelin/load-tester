#!/bin/bash
# [한 머신 멀티 인스턴스] vUser를 여러 JMeter 프로세스로 나눠 실행하고 결과를 병합한다.
# 다코어 단일 머신(예: 40코어)에서 단일 JVM의 힙/GC 한계를 피해 큰 부하를 만들 때 사용.
# (여러 "머신"을 묶는 agent 모드와 다름 — 한 대면 이 방식이 더 간단하다)
#
# 사용법: ./scripts/run-multi.sh <인스턴스수> <총vUser> <서버IP> [PORT] [THINK_MS] [DURATION]
# 예:     ./scripts/run-multi.sh 2 40000 10.0.0.20 18080 1000 300
#         → 2개 프로세스 × 20,000명 = 총 40,000 vUser (인스턴스당 힙 8g)
set -uo pipefail
cd "$(dirname "$0")/.."

INST=${1:?사용법: run-multi.sh <인스턴스수> <총vUser> <서버IP> [PORT] [THINK_MS] [DURATION]}
TOTAL=${2:?총 vUser 수}
HOST=${3:?대상 서버 IP}
PORT=${4:-18080}
THINK=${5:-1000}
DURATION=${6:-300}

PER=$(( TOTAL / INST ))
RAMP=$(( PER / 100 )); [ "$RAMP" -lt 10 ] && RAMP=10

ulimit -n 65536
JBIN=java; [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] && JBIN="$JAVA_HOME/bin/java"
JMAJ=$("$JBIN" -version 2>&1 | awk -F'"' '/version/{split($2,v,"."); print (v[1]==1)?v[2]:v[1]}')
if [ "${JMAJ:-0}" -lt 17 ] && [ "${FORCE_JAVA:-0}" != "1" ]; then
  echo "오류: $("$JBIN" -version 2>&1 | head -1) — JDK 17 필요 (DEPLOY.md 3장)"; exit 1
fi
[ "$PER" -gt 25000 ] && echo "경고: 인스턴스당 ${PER}명 — 25,000 초과. 인스턴스 수를 늘리는 것을 권장"

mkdir -p results
RUN="multi_$(date +%m%d%H%M%S)"

echo "=== 멀티 인스턴스 | ${INST}개 × ${PER}명 = 총 $(( PER * INST ))명 | think ${THINK}ms | ${HOST}:${PORT} | ${DURATION}s ==="
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup INT TERM
for i in $(seq 1 "$INST"); do
  TAG="${RUN}_i${i}"
  rm -f "results/result_$TAG.jtl"   # -l 은 기존 파일에 append 하므로 반드시 제거
  JVM_ARGS="-Xms2g -Xmx8g -Xss256k" jmeter -n -t "${PLAN:-echo-load.jmx}" \
    -Jhost="$HOST" -Jport="$PORT" -Jthreads="$PER" -Jrampup="$RAMP" \
    -Jduration="$DURATION" -Jthinkms="$THINK" \
    -l "results/result_$TAG.jtl" -j "results/jmeter_$TAG.log" \
    > "results/stdout_$TAG.txt" 2>&1 &
  PID=$!
  PIDS+=("$PID")
  echo "  인스턴스 $i 시작 (pid $PID) → results/result_$TAG.jtl"
done

echo "전체 종료 대기 중... (진행 상황: tail -f results/stdout_${RUN}_i1.txt)"
FAIL=0
for p in "${PIDS[@]}"; do wait "$p" || FAIL=1; done
[ "$FAIL" = 1 ] && echo "경고: 일부 인스턴스 비정상 종료 — results/jmeter_${RUN}_i*.log 확인"

# jtl 병합 (첫 파일은 헤더 포함, 나머지는 헤더 제외)
MERGED="results/result_${RUN}_merged.jtl"
head -1 "results/result_${RUN}_i1.jtl" > "$MERGED"
for i in $(seq 1 "$INST"); do tail -n +2 "results/result_${RUN}_i${i}.jtl" >> "$MERGED"; done

echo ""
echo "===== 합산 결과 (${INST}개 인스턴스 병합, 램프업 ${RAMP}s 제외) ====="
./scripts/summarize-jtl.sh "$MERGED" "$RAMP"

if [ "${REPORT:-0}" = "1" ]; then
  echo "HTML 리포트 생성 중... → results/report_${RUN}/index.html"
  rm -rf "results/report_${RUN}"
  JVM_ARGS="-Xms1g -Xmx6g" jmeter -g "$MERGED" -o "results/report_${RUN}" >/dev/null
else
  echo "HTML 리포트: JVM_ARGS=-Xmx6g jmeter -g $MERGED -o results/report_${RUN}/"
fi