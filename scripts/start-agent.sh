#!/bin/bash
# [에이전트 머신에서 실행] JMeter 에이전트(jmeter-server) 기동
# 사용법: ./scripts/start-agent.sh <이 머신의 IP>
# 전제: Java 8 이상 + JMeter가 PATH에 있을 것 (DEPLOY.md 3장), 마스터와 JMeter 버전 동일
set -euo pipefail
cd "$(dirname "$0")/.."

MYIP=${1:?사용법: start-agent.sh <이 에이전트 머신의 IP>}

# 파일 디스크립터 한도 — 하드 한도까지만 올리고, 낮으면 경고 후 계속 (하드 한도 상향은 TUNING.md 6-2 요청)
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
NOFILE=$(ulimit -n)
if [ "$NOFILE" != "unlimited" ] && [ "$NOFILE" -lt 65536 ]; then
  echo "경고: open files 한도가 $NOFILE 입니다 (권장 65536). 스레드 수가 이 값에 가까우면 'Too many open files'로 실패합니다."
  echo "      영구 상향: /etc/security/limits.d/90-loadtest.conf (TUNING.md 6-2) 적용 후 재로그인"
fi

JBIN=java; [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] && JBIN="$JAVA_HOME/bin/java"
JMAJ=$("$JBIN" -version 2>&1 | awk -F'"' '/version/{split($2,v,"."); print (v[1]==1)?v[2]:v[1]}')
if [ "${JMAJ:-0}" -lt 8 ] && [ "${FORCE_JAVA:-0}" != "1" ]; then
  echo "오류: $("$JBIN" -version 2>&1 | head -1) — Java 8 이상 필요 (DEPLOY.md 3장)"; exit 1
fi

echo "=== JMeter 에이전트 기동: ${MYIP}:1099 (마스터가 -R ${MYIP} 로 접속) ==="
echo "    부하는 이 머신이 만든다 — 힙 8g / 커널 튜닝(TUNING.md 1-B)은 이 머신에 적용돼 있어야 함"
JVM_ARGS="-Xms2g -Xmx8g -Xss256k" jmeter-server \
  -Dserver.rmi.ssl.disable=true \
  -Djava.rmi.server.hostname="$MYIP"