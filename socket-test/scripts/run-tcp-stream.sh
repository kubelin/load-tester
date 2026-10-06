#!/bin/bash
# TCP 생소켓 시세 수신 실행 래퍼 — 고정길이 전문. JSON 아님(바이너리/고정폭 전문).
# 사용법: ./run-tcp-stream.sh <연결수> <서버호스트> <포트> [지속s] [램프s]
#
# 필수 env:
#   TCP_MSGLEN=200   한 전문의 바이트 수 (고정길이)
# 구독 전문 (택1):
#   TCP_SUBFILE=sub.txt   구독 전문 파일 ({IDX}/{KEY} 치환)
#   TCP_SUB='...'         인라인
#   TCP_SUBKEYS='005930,000660'  종목 라운드로빈 → {KEY}
#   TCP_ENCODING=euc-kr   구독 전문 인코딩 (기본 utf-8)
# 저장:
#   TCP_DUMP=0            대량접속 시 저장 끄기 (기본 1=켬)
#   DUMP_N=50            앞 50연결만 저장 (표본)
#   TCP_DUMPFMT=hex      hex(기본) | text(디코드) | raw(.bin 원본바이트)
#   TCP_DUMPDIR=dumps    저장 위치
#
# 예) 소수 + 전체저장(text로 눈으로 확인):
#   TCP_MSGLEN=200 TCP_SUBFILE=sub.txt TCP_SUBKEYS='005930,000660' TCP_DUMPFMT=text \
#     ./run-tcp-stream.sh 20 10.0.0.50 9000 120
# 예) 대량 부하 + 저장 OFF:
#   TCP_MSGLEN=200 TCP_SUB='SUB|{KEY}' TCP_SUBKEYS='005930' TCP_DUMP=0 \
#     ./run-tcp-stream.sh 5000 10.0.0.50 9000 180
set -uo pipefail
cd "$(dirname "$0")/.."

CONNS=${1:?사용법: run-tcp-stream.sh <연결수> <서버호스트> <포트> [지속s] [램프s]}
HOST=${2:?서버 호스트}
PORT=${3:?포트}
DURATION=${4:-120}
RAMP=${5:-$(( CONNS / 200 ))}; [ "$RAMP" -lt 3 ] && RAMP=3

command -v python3 >/dev/null || { echo "python3 없음"; exit 1; }
[ -n "${TCP_MSGLEN:-}" ] || { echo "오류: TCP_MSGLEN(고정 전문 길이) 지정 필요. 예: TCP_MSGLEN=200"; exit 1; }
ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true

echo "=== TCP 시세수신 | ${CONNS}연결 | ${HOST}:${PORT} | 전문 ${TCP_MSGLEN}B | ${DURATION}s | 저장=$([ "${TCP_DUMP:-1}" = "0" ] && echo OFF || echo ON) ==="
exec python3 scripts/tcp_streamclient.py "$CONNS" "$DURATION" "$HOST" "$PORT" "$RAMP"
