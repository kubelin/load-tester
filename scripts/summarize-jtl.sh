#!/bin/bash
# jtl → 결과서용 지표 요약 (awk/sort만 사용 — RHEL 7 호환, python 불필요)
# 사용법: ./scripts/summarize-jtl.sh <result.jtl> [램프업제외초]
#   예:   ./scripts/summarize-jtl.sh results/result_target10000_09071030.jtl 30
#   → 앞 30초(램프업)를 제외한 정상상태 구간의 지표를 출력한다.
set -euo pipefail
F=${1:?사용법: summarize-jtl.sh <result.jtl> [램프업제외초]}
SKIP=${2:-0}

[ -s "$F" ] || { echo "파일 없음/비어있음: $F"; exit 1; }
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

T0=$(awk -F, 'NR==2{print $1; exit}' "$F")
CUT=$(( T0 + SKIP*1000 ))

# elapsed(2열)는 인용부호 필드보다 앞이라 항상 안전. 성공 여부는 ',true,' 존재로 판정.
STATS=$(awk -F, -v cut="$CUT" -v tmp="$TMP" '
  NR>1 && $1>=cut {
    print $2 > tmp
    n++; sum+=$2
    if ($0 ~ /,true,/) ok++
    if (mn==0 || $1<mn) mn=$1
    if ($1>mx) mx=$1
  }
  END {
    dur=(mx-mn)/1000; if (dur<=0) dur=1
    printf "%d %d %.1f %.2f %.1f", n, n-ok, n/dur, (n-ok)*100.0/n, sum/n
  }' "$F")
read -r N ERRS TPS ERRP AVG <<< "$STATS"

sort -n "$TMP" -o "$TMP"
pct() { awk -v q="$1" -v n="$N" 'NR==int(n*q)+1{print; exit} END{if(NR<int(n*q)+1) print $0}' "$TMP"; }
P50=$(pct 0.50); P90=$(pct 0.90); P95=$(pct 0.95); P99=$(pct 0.99)
MAX=$(tail -1 "$TMP")

echo "파일: $F  (램프업 ${SKIP}s 제외, 표본 ${N}건)"
echo "──────────────────────────────────────────────"
printf "%-14s %s\n" "TPS(정상상태)" "${TPS}/s"
printf "%-14s %s (%s건)\n" "에러율"       "${ERRP}%" "$ERRS"
printf "%-14s %sms\n" "응답 평균"     "$AVG"
printf "%-14s p50=%sms  p90=%sms  p95=%sms  p99=%sms  max=%sms\n" "응답 분포" "$P50" "$P90" "$P95" "$P99" "$MAX"