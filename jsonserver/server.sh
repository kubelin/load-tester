#!/bin/bash
# dummy-json 서버 기동/중지 스크립트 — 포트별로 여러 인스턴스를 띄울 수 있다.
# 로그와 pid는 LOGDIR(기본: "명령을 실행한 현재 폴더"/logs)에 쌓이고, 바이너리는 스크립트 옆에서 찾는다.
# 사용법: ./server.sh start [포트]   (기본 18080)
#         ./server.sh stop  [포트]
#         ./server.sh status [포트]  (포트 생략 시 실행 중인 인스턴스 전부 표시)
# 인스턴스별 파일 (같은 LOGDIR 안에서 포트로 구분):
#   $LOGDIR/server_<포트>.pid           pid
#   $LOGDIR/server_<포트>_<시각>.log    기동 배너·오류
#   $LOGDIR/access_<포트>_<시각>.log    액세스 로그 (로테이션·보관 정리는 같은 포트 파일끼리만)
# 환경변수(start 전용):
#   LOGDIR=<경로>   로그·pid 디렉터리 (기본 ./logs). 절대경로 권장, 예: LOGDIR=/var/log/dummy-json
#   BIN=<경로>      실행할 바이너리 (기본: 스크립트 옆의 OS별 바이너리). 다른 빌드를 띄울 때 지정
#   ACCESSLOG=0     액세스 로그 끄기 (기본 1 = $LOGDIR/access_<포트>_*.log 기록)
#   LOGMAXMB=100    액세스 로그 파일이 이 크기(MB)를 넘으면 새 파일로 로테이션 (0 = 안 함)
#   LOGMAXFILES=10  $LOGDIR 에 남길 이 포트의 access 파일 최대 개수, 오래된 것부터 삭제 (0 = 무제한)
# 예: ./server.sh start 18080 && ./server.sh start 18081     (두 인스턴스)
#     ACCESSLOG=0 ./server.sh start                          (요청 로그 없이 기동)
#     BIN=./dummy-json-new ./server.sh start 18081           (다른 빌드를 두 번째 포트에)
#     LOGDIR=/data/loadtest/logs ./server.sh start
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CMD=${1:-status}
PORT=${2:-18080}
PORT_GIVEN=${2:-}
LOGDIR=${LOGDIR:-logs}
PIDFILE=$LOGDIR/server_$PORT.pid
ACCESSLOG=${ACCESSLOG:-1}
LOGMAXMB=${LOGMAXMB:-100}
LOGMAXFILES=${LOGMAXFILES:-10}

# OS에 맞는 바이너리 선택 (RHEL: linux-amd64, 맥 로컬 테스트: darwin). BIN 환경변수로 덮어쓸 수 있다.
if [ -z "${BIN:-}" ]; then
  case "$(uname -s)" in
    Linux)  BIN="$SCRIPT_DIR/dummy-json-linux-amd64" ;;
    Darwin) BIN="$SCRIPT_DIR/dummy-json-darwin" ;;
    *) echo "지원하지 않는 OS"; exit 1 ;;
  esac
fi

running() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

show() {  # show <pidfile>
  local pf=$1 port pid
  port=$(basename "$pf" .pid); port=${port#server_}
  pid=$(cat "$pf")
  echo "포트 $port: 실행 중 (pid $pid)"
  echo "  최근 액세스 로그: $(ls -t "$LOGDIR"/access_"$port"_*.log 2>/dev/null | head -1)"
}

case "$CMD" in
  start)
    [ -x "$BIN" ] || { echo "바이너리 없음: $BIN (README.md 빌드 참고)"; exit 1; }
    if running "$PIDFILE"; then echo "포트 $PORT 이미 실행 중 (pid $(cat "$PIDFILE"))"; exit 0; fi
    if ! mkdir -p "$LOGDIR" 2>/dev/null || ! touch "$LOGDIR/.w" 2>/dev/null; then
      echo "오류: 로그 디렉터리 $LOGDIR 를 만들 권한이 없다. (현재 위치: $(pwd))"
      echo "  해결: LOGDIR=~/dummy-json-logs 처럼 쓸 수 있는 경로 지정, 또는 sudo chown -R \$(whoami) <경로>"
      exit 1
    fi
    rm -f "$LOGDIR/.w"
    ulimit -n 65536
    TS=$(date +%Y%m%d_%H%M%S)
    SERVERLOG="$LOGDIR/server_${PORT}_$TS.log"
    LOGOPTS=()
    if [ "$ACCESSLOG" != "0" ]; then
      LOGOPTS=(-logdir "$LOGDIR" -logname "access_$PORT" -logmaxmb "$LOGMAXMB" -logmaxfiles "$LOGMAXFILES")
    fi
    nohup "$BIN" -port "$PORT" "${LOGOPTS[@]}" > "$SERVERLOG" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    if running "$PIDFILE" && curl -sf -m 3 "http://127.0.0.1:$PORT/health" >/dev/null; then
      echo "기동 완료 (pid $(cat "$PIDFILE"), port $PORT, bin $BIN)"
      echo "  서버 로그:   $SERVERLOG"
      if [ "$ACCESSLOG" != "0" ]; then
        echo "  액세스 로그: $(ls -t "$LOGDIR"/access_"$PORT"_*.log 2>/dev/null | head -1)  (${LOGMAXMB}MB 단위 로테이션, 최대 ${LOGMAXFILES}개 보관)"
      else
        echo "  액세스 로그: 꺼짐 (ACCESSLOG=0)"
      fi
    else
      echo "기동 실패 — $SERVERLOG 확인:"; tail -5 "$SERVERLOG"
      rm -f "$PIDFILE"; exit 1
    fi
    ;;
  stop)
    if running "$PIDFILE"; then
      kill "$(cat "$PIDFILE")" && echo "포트 $PORT 종료됨 (pid $(cat "$PIDFILE"))"
      rm -f "$PIDFILE"
    else
      echo "포트 $PORT 실행 중 아님"; rm -f "$PIDFILE"
    fi
    ;;
  status)
    if [ -n "$PORT_GIVEN" ]; then
      if running "$PIDFILE"; then show "$PIDFILE"; else echo "포트 $PORT: 중지 상태"; fi
    else
      found=0
      for pf in "$LOGDIR"/server_*.pid; do
        [ -f "$pf" ] || continue
        if running "$pf"; then show "$pf"; found=1; else rm -f "$pf"; fi
      done
      [ "$found" = 1 ] || echo "실행 중인 인스턴스 없음"
    fi
    ;;
  *) echo "사용법: ./server.sh start [포트] | stop [포트] | status [포트]"; exit 1 ;;
esac
