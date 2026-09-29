#!/bin/bash
# dummy-json 서버 기동/중지 스크립트
# 로그와 pid는 LOGDIR(기본: "명령을 실행한 현재 폴더"/logs)에 쌓이고, 바이너리는 스크립트 옆에서 찾는다.
# 사용법: ./server.sh start [포트]   (기본 18080)
#         ./server.sh stop
#         ./server.sh status
# 환경변수(start 전용):
#   LOGDIR=<경로>   로그·pid 디렉터리 (기본 ./logs). 절대경로 권장, 예: LOGDIR=/var/log/dummy-json
#   ACCESSLOG=0     액세스 로그 끄기 (기본 1 = $LOGDIR/access_*.log 기록)
#   LOGMAXMB=100    액세스 로그 파일이 이 크기(MB)를 넘으면 새 파일로 로테이션 (0 = 안 함)
#   LOGMAXFILES=10  $LOGDIR 에 남길 access_*.log 최대 개수, 오래된 것부터 삭제 (0 = 무제한)
# 예: ACCESSLOG=0 ./server.sh start            (요청 로그 없이 기동)
#     LOGDIR=/data/loadtest/logs ./server.sh start
#     LOGMAXMB=500 LOGMAXFILES=20 ./server.sh start
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CMD=${1:-status}
PORT=${2:-18080}
LOGDIR=${LOGDIR:-logs}
PIDFILE=$LOGDIR/server.pid
ACCESSLOG=${ACCESSLOG:-1}
LOGMAXMB=${LOGMAXMB:-100}
LOGMAXFILES=${LOGMAXFILES:-10}

# OS에 맞는 바이너리 선택 (RHEL: linux-amd64, 맥 로컬 테스트: darwin)
case "$(uname -s)" in
  Linux)  BIN="$SCRIPT_DIR/dummy-json-linux-amd64" ;;
  Darwin) BIN="$SCRIPT_DIR/dummy-json-darwin" ;;
  *) echo "지원하지 않는 OS"; exit 1 ;;
esac
[ -x "$BIN" ] || { echo "바이너리 없음: $BIN (README.md 빌드 참고)"; exit 1; }

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "$CMD" in
  start)
    if running; then echo "이미 실행 중 (pid $(cat "$PIDFILE"))"; exit 0; fi
    if ! mkdir -p "$LOGDIR" 2>/dev/null || ! touch "$LOGDIR/.w" 2>/dev/null; then
      echo "오류: 로그 디렉터리 $LOGDIR 를 만들 권한이 없다. (현재 위치: $(pwd))"
      echo "  해결: LOGDIR=~/dummy-json-logs 처럼 쓸 수 있는 경로 지정, 또는 sudo chown -R \$(whoami) <경로>"
      exit 1
    fi
    rm -f "$LOGDIR/.w"
    ulimit -n 65536
    TS=$(date +%Y%m%d_%H%M%S)
    LOGOPTS=()
    if [ "$ACCESSLOG" != "0" ]; then
      LOGOPTS=(-logdir "$LOGDIR" -logmaxmb "$LOGMAXMB" -logmaxfiles "$LOGMAXFILES")
    fi
    nohup "$BIN" -port "$PORT" "${LOGOPTS[@]}" > "$LOGDIR/server_$TS.log" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    if curl -sf -m 3 "http://127.0.0.1:$PORT/health" >/dev/null; then
      echo "기동 완료 (pid $(cat "$PIDFILE"), port $PORT)"
      echo "  서버 로그:   $LOGDIR/server_$TS.log"
      if [ "$ACCESSLOG" != "0" ]; then
        echo "  액세스 로그: $(ls -t "$LOGDIR"/access_*.log 2>/dev/null | head -1)  (${LOGMAXMB}MB 단위 로테이션, 최대 ${LOGMAXFILES}개 보관)"
      else
        echo "  액세스 로그: 꺼짐 (ACCESSLOG=0)"
      fi
    else
      echo "기동 실패 — $LOGDIR/server_$TS.log 확인:"; tail -5 "$LOGDIR/server_$TS.log"
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
      echo "  최근 액세스 로그: $(ls -t "$LOGDIR"/access_*.log 2>/dev/null | head -1)"
    else
      echo "중지 상태"
    fi
    ;;
  *) echo "사용법: ./server.sh start [포트] | stop | status"; exit 1 ;;
esac