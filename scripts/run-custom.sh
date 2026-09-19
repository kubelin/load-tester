#!/bin/bash
# /custom(사내 규격) 부하 실행기 — custom.jmx + custom-body.json 한 세트로 모든 모드를 돌린다.
#
# 사용법:
#   ./scripts/run-custom.sh once   [HOST] [PORT]                        # 1건만 보내고 요청/응답 출력 (규격 확인)
#   ./scripts/run-custom.sh tps    <TPS>     [HOST] [PORT] [DURATION초]  # 고정 TPS 유지 (결과서용)
#   ./scripts/run-custom.sh vusers <vUser수> [HOST] [PORT] [THINK_MS] [DURATION초]
#   ./scripts/run-custom.sh max    [HOST] [PORT]                        # 최대 TPS 탐색 (스레드 단계 증가)
#
# 레버 (환경변수, 모두 선택):
#   BODY=custom-body.json   요청 바디 템플릿 파일
#   REQBYTES=0              요청 바디 팽창 바이트 (JMeter가 최상위 _pad 필드에 랜덤 문자열 생성)
#   RESPKB=0                응답 팽창 KB          (서버가 ?respKB= 로 생성)
#   DELAYMS=0               서버 처리 지연 ms     (서버가 ?delay= 로 sleep)
#   FAIL=0                  실패 주입 비율 0~1    (서버가 ?fail= 비율만큼 rtrnCd 999 응답, HTTP 200)
#   REPORT=1                종료 후 HTML 리포트 자동 생성
#   EXTRA_JOPTS="-J..."     그 밖의 JMeter 프로퍼티 추가 전달
#
# 예:
#   ./scripts/run-custom.sh once 192.168.0.10 18080
#   ./scripts/run-custom.sh tps 10000 192.168.0.10 18080 300
#   RESPKB=5120 DELAYMS=200 ./scripts/run-custom.sh vusers 2000 192.168.0.10 18080 0 300
set -euo pipefail
ORIG_PWD=$PWD
cd "$(dirname "$0")/.."

MODE=${1:-}
[ -n "$MODE" ] || { sed -n '2,20p' "$0"; exit 1; }
shift

# --- 바디 템플릿: 원래 실행 위치 기준 → 없으면 레포 루트 기준 → 절대경로로 고정 (JMeter cwd 무관)
BODY=${BODY:-custom-body.json}
if   [ -f "$ORIG_PWD/$BODY" ]; then BODY=$(readlink -f "$ORIG_PWD/$BODY")
elif [ -f "$BODY" ];           then BODY=$(readlink -f "$BODY")
else echo "오류: 바디 템플릿 파일이 없습니다: $BODY"; exit 1; fi

# --- 레버 → -J 프로퍼티. 0이면 플랜이 쿼리스트링을 붙이지 않고 _pad는 빈 문자열이다 (custom.jmx 주석 참고)
REQBYTES=${REQBYTES:-0}; RESPKB=${RESPKB:-0}; DELAYMS=${DELAYMS:-0}; FAIL=${FAIL:-0}
export PLAN=custom.jmx
export EXTRA_JOPTS="-Jbody=$BODY -Jreqbytes=$REQBYTES -Jrespkb=$RESPKB -Jdelayms=$DELAYMS -Jfail=$FAIL ${EXTRA_JOPTS:-}"

LEVERS=""
[ "$REQBYTES" != "0" ] && LEVERS+=" 요청팽창=${REQBYTES}B"
[ "$RESPKB"   != "0" ] && LEVERS+=" 응답팽창=${RESPKB}KB"
[ "$DELAYMS"  != "0" ] && LEVERS+=" 서버지연=${DELAYMS}ms"
[ "$FAIL"     != "0" ] && LEVERS+=" 실패주입=${FAIL}"
echo "[custom] body=$BODY${LEVERS:+ | 레버:$LEVERS}"

case "$MODE" in
  tps)    exec ./scripts/run-target-tps.sh "$@" ;;
  vusers) exec ./scripts/run-vusers.sh "$@" ;;
  max)    exec ./scripts/run-max-tps.sh "$@" ;;
  once)   ;;  # 아래에서 처리
  *)      echo "모드는 once | tps | vusers | max 중 하나"; exit 1 ;;
esac

# ============================================================================
# once — 스레드 1개가 딱 1건 보내고, 실제 전송된 요청 바디와 응답을 그대로 보여준다.
#        custom-body.json 수정 후 규격이 맞는지, 서버가 rtrnCd 000을 주는지 확인하는 용도.
# ============================================================================
HOST=${1:-127.0.0.1}
PORT=${2:-18082}

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
TAG="once_$(date +%m%d%H%M%S)"
OUT="results/$TAG.xml"

echo "=== 1건 전송 → ${HOST}:${PORT} ==="
# shellcheck disable=SC2086
JVM_ARGS="-Xms256m -Xmx1g" jmeter -n -t custom.jmx \
  -Jhost="$HOST" -Jport="$PORT" -Jthreads=1 -Jrampup=1 -Jloops=1 $EXTRA_JOPTS \
  -Jjmeter.save.saveservice.output_format=xml \
  -Jjmeter.save.saveservice.samplerData=true \
  -Jjmeter.save.saveservice.response_data=true \
  -Jjmeter.save.saveservice.requestHeaders=true \
  -l "$OUT" -j "results/jmeter_$TAG.log" >/dev/null 2>&1 || true

if ! grep -q "<httpSample" "$OUT" 2>/dev/null; then
  echo "오류: 샘플이 기록되지 않았습니다. results/jmeter_$TAG.log 확인 (바디 파일 경로, 함수 문법 등)"
  exit 1
fi

# XML 이스케이프 복원 / 태그 본문 추출 (한 줄에 여닫는 태그도 처리)
unesc() { sed -e 's/&quot;/"/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&#xd;//g' -e 's/&amp;/\&/g'; }
tag()   { awk -v t="$1" 'BEGIN{RS="\0"} index($0,"<"t){sub("^.*<"t"[^>]*>",""); sub("</"t">.*$",""); print}' "$OUT" | unesc; }
attr()  { grep -m1 "<httpSample" "$OUT" | grep -oE " $1=\"[^\"]*\"" | cut -d'"' -f2; }

echo ""
echo "--- 요청: POST $(tag java.net.URL)"
tag requestHeader | grep -oE "Content-Length: [0-9]+" || true
tag queryString
echo ""
ASSERT=$(grep -A2 "<assertionResult>" "$OUT" | grep -q "<failure>true" && echo "실패" || echo "통과")
echo "--- 응답: HTTP $(attr rc) $(attr rm) | $(attr t)ms | $(attr by) bytes | rtrnCd 검증: $ASSERT"
tag responseData | head -c 4000
echo ""
echo ""
echo "원본: $OUT"
