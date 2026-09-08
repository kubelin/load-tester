#!/bin/bash
# dummy-json 서버 기동/중지 스크립트 — 로그는 전부 ./logs/ 에 쌓인다.
# 사용법: ./server.sh start [포트]   (기본 18080)
#         ./server.sh stop
#         ./server.sh status
set -uo pipefail
cd "$(dirname "$0")"

CMD=${1:-status}
PORT=${2:-18080}
PIDFILE=logs/server.pid

# OS에 맞는 바이너리 선택 (RHEL: linux-amd64, 맥 로컬 테스트: darwin)
case "$(uname -s)" in
  Linux)  BIN=./dummy-json-linux-amd64 ;;
  Darwin) BIN=./dummy-json-darwin ;;
  *) echo "지원하지 않는 OS"; exit 1 ;;
esac
[ -x "$BIN" ] || { echo "바이너리 없음: $BIN (README.md 빌드 참고)"; exit 1; }

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "$CMD" in
  start)
    if running; then echo "이미 실행 중 (pid $(cat "$PIDFILE"))"; exit 0; fi
    if ! mkdir -p logs 2>/dev/null || ! touch logs/.w 2>/dev/null; then
      echo "오류: 현재 위치($(pwd))에 logs/ 를 만들 권한이 없다."
      echo "  해결: sudo chown -R \$(whoami) $(pwd)   또는 홈 디렉터리로 옮겨 실행"
      exit 1
    fi
    rm -f logs/.w
    ulimit -n 65536
    TS=$(date +%Y%m%d_%H%M%S)
    nohup "$BIN" -port "$PORT" -logdir logs > "logs/server_$TS.log" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    if curl -sf -m 3 "http://127.0.0.1:$PORT/health" >/dev/null; then
      echo "기동 완료 (pid $(cat "$PIDFILE"), port $PORT)"
      echo "  서버 로그:   logs/server_$TS.log"
      echo "  액세스 로그: $(ls -t logs/access_*.log 2>/dev/null | head -1)"
    else
      echo "기동 실패 — logs/server_$TS.log 확인:"; tail -5 "logs/server_$TS.log"
      rm -f "$PIDFILE"; exit 1
    fi
    ;;
  stop)
    if running; then
      kill "$(cat "$PIDFILE")" && echo "종료됨 (pid $(cat "$PIDFILE"))"
      rm -f "$PIDFILE"
    else
      echo "실행 중 아님"; rm -f "$PIDFILE"
    fi
    ;;
  status)
    if running; then
      echo "실행 중 (pid $(cat "$PIDFILE"))"
      echo "  최근 액세스 로그: $(ls -t logs/access_*.log 2>/dev/null | head -1)"
    else
      echo "중지 상태"
    fi
    ;;
  *) echo "사용법: ./server.sh start [포트] | stop | status"; exit 1 ;;
esac