#!/bin/bash
# [에이전트 머신에서 실행] JMeter 에이전트(jmeter-server) 기동
# 사용법: ./scripts/start-agent.sh <이 머신의 IP>
# 전제: JDK17 + JMeter가 PATH에 있을 것 (DEPLOY.md 3장), 마스터와 JMeter 버전 동일
set -euo pipefail
cd "$(dirname "$0")/.."

MYIP=${1:?사용법: start-agent.sh <이 에이전트 머신의 IP>}

ulimit -n 65536

JBIN=java; [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] && JBIN="$JAVA_HOME/bin/java"
JMAJ=$("$JBIN" -version 2>&1 | awk -F'"' '/version/{split($2,v,"."); print (v[1]==1)?v[2]:v[1]}')
if [ "${JMAJ:-0}" -lt 17 ] && [ "${FORCE_JAVA:-0}" != "1" ]; then
  echo "오류: $("$JBIN" -version 2>&1 | head -1) — JDK 17 필요 (DEPLOY.md 3장)"; exit 1
fi

echo "=== JMeter 에이전트 기동: ${MYIP}:1099 (마스터가 -R ${MYIP} 로 접속) ==="
echo "    부하는 이 머신이 만든다 — 힙 8g / 커널 튜닝(TUNING.md 1-B)은 이 머신에 적용돼 있어야 함"
JVM_ARGS="-Xms2g -Xmx8g -Xss256k" jmeter-server \
  -Dserver.rmi.ssl.disable=true \
  -Djava.rmi.server.hostname="$MYIP"