#!/bin/bash
# WebSocket 시세 수신 실행 래퍼 — JSON 구독 → 수신 원문 저장 (대량 시 저장 OFF).
# 사용법: ./run-ws-stream.sh <연결수> <서버호스트> [포트] [경로] [지속s] [램프s]
#
# 구독 메시지 지정 (택1, env):
#   WS_SUBFILE=sub.json   구독 JSON 파일 ({IDX}/{KEY} 치환 가능)
#   WS_SUB='{"...":"{KEY}"}'  인라인 JSON
#   WS_SUBKEYS='005930,000660'  종목코드 목록 (연결마다 라운드로빈 → {KEY})
# 저장:
#   기본 저장 ON. 대량접속은  WS_DUMP=0  으로 끄기.  DUMP_N=50 이면 앞 50연결만 저장.
#   WS_DUMPDIR=dumps  저장 위치 (연결별 conn_<idx>.dat + sessions_<시각>.csv)
#
# 예) 소수 연결 + 전체 원문 저장:
#   WS_SUBFILE=sub.json WS_SUBKEYS='005930,000660' ./run-ws-stream.sh 20 10.0.0.50 8080 /ws 120
# 예) 대량 접속 + 저장 OFF (부하만):
#   WS_SUB='{"body":{"tr_key":"{KEY}"}}' WS_SUBKEYS='005930' WS_DUMP=0 ./run-ws-stream.sh 5000 10.0.0.50 8080 /ws 180
set -uo pipefail
cd "$(dirname "$0")/.."

CONNS=${1:?사용법: run-ws-stream.sh <연결수> <서버호스트> [포트] [경로] [지속s] [램프s]}
HOST=${2:?서버 호스트}
PORT=${3:-8080}
WPATH=${4:-/ws/test}
DURATION=${5:-120}
RAMP=${6:-$(( CONNS / 200 ))}; [ "$RAMP" -lt 3 ] && RAMP=3

command -v python3 >/dev/null || { echo "python3 없음"; exit 1; }
python3 -c "import websockets" 2>/dev/null || { echo "websockets 미설치: pip install --user 'websockets==8.1'"; exit 1; }
ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true

echo "=== WS 시세수신 | ${CONNS}연결 | ${HOST}:${PORT}${WPATH} | ${DURATION}s | 저장=$([ "${WS_DUMP:-1}" = "0" ] && echo OFF || echo ON) ==="
exec python3 scripts/ws_streamclient.py "$CONNS" "$DURATION" "$HOST" "$PORT" "$WPATH" "$RAMP"
