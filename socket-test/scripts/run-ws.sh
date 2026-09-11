#!/bin/bash
# WebSocket 수신 부하 실행 래퍼 — 스레드 1개 = 커넥션 1개로 동시 연결 N개를 유지하며
# 서버가 밀어주는 데이터를 계속 수신한다. (ws-load.jmx)
#
# 사용법: ./run-ws.sh <CONNS> <HOST> [PORT] [WSPATH] [DURATION초] [INTERVALms]
#   예:   ./run-ws.sh 500 10.0.0.20 8080 /ws 120 0
#
# 접속 즉시 서버가 push → 구독 메시지 불필요:   SUBSCRIBE=false ./run-ws.sh ...
# 구독 메시지가 필요하면(기본)  ws-load.jmx 의 "Send subscribe JSON" requestData 를 규격에 맞게 수정.
# 수신 데이터 검증:  EXPECT='"type":"data"' ./run-ws.sh ...
# TLS(wss):          TLS=true ./run-ws.sh ...
#
# 전제: JMeter 에 WebSocket Samplers 플러그인이 설치돼 있어야 함.
#   cp offline/jmeter-plugins/jmeter-websocket-samplers-*.jar  $JMETER_HOME/lib/ext/
set -u
CONNS="${1:?동시 연결 수 필요}"
HOST="${2:?대상 호스트 필요}"
PORT="${3:-8080}"
WSPATH="${4:-/ws/test}"
DUR="${5:-60}"
INTERVAL="${6:-0}"
SUBSCRIBE="${SUBSCRIBE:-true}"
SUBMSG="${SUBMSG:-hello}"     # 접속 후 보낼 트리거 메시지(평문). 예: 'hello' 또는 'hello 200'
PLAN="${PLAN:-ws-load.jmx}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="ws_$(date +%Y%m%d_%H%M%S)"

command -v jmeter >/dev/null || { echo "jmeter 가 PATH에 없습니다 (DEPLOY.md 3장)"; exit 1; }

# 동시 연결이 많으면 발생기 FD 한도부터 (연결 1개 = FD 1개)
if [ "$(ulimit -Sn)" -lt $((CONNS + 1000)) ]; then
  echo "!! ulimit -n=$(ulimit -Sn) 이 연결수+여유보다 작습니다. 'ulimit -n 65536' 후 재실행 권장."
fi

echo "== WS 수신부하: 연결=${CONNS}  대상=ws://${HOST}:${PORT}${WSPATH}  ${DUR}s  구독=${SUBSCRIBE}  간격=${INTERVAL}ms =="
JVM_ARGS="-Xms1g -Xmx4g -Xss256k" jmeter -n -t "$HERE/$PLAN" \
  -Jconns="$CONNS" -Jhost="$HOST" -Jport="$PORT" -Jwspath="$WSPATH" \
  -Jduration="$DUR" -Jintervalms="$INTERVAL" -Jsubscribe="$SUBSCRIBE" -Jsubmsg="$SUBMSG" \
  ${EXPECT:+-Jexpect="$EXPECT"} ${TLS:+-Jtls="$TLS"} \
  -l "$HERE/${STAMP}.jtl" -j "$HERE/${STAMP}.log"

echo
echo "결과: ${STAMP}.jtl   (HTML 리포트: jmeter -g ${STAMP}.jtl -o ${STAMP}_report/)"
