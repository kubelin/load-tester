#!/bin/bash
# 부하 발생기(Linux/RHEL) 커널 파라미터 점검 스크립트
# root 불필요 (조회만 한다). 결과를 인프라팀 변경 요청서에 첨부하면 된다.
# 사용법: ./check-kernel-loadgen.sh

echo "=== 부하 발생기 커널 파라미터 점검 ($(hostname), $(date '+%Y-%m-%d %H:%M')) ==="
echo ""

pass=0; fail=0

# check <라벨> <현재값> <권장값> <비교방식: ge(이상이면OK) | le(이하면OK) | eq(일치해야OK)>
check() {
  local label="$1" cur="$2" want="$3" mode="$4" ok
  if [ -z "$cur" ]; then
    printf "  [조회불가] %-36s (이 OS에 없는 키 — RHEL에서 실행할 것)\n" "$label"
    return
  fi
  case "$mode" in
    ge) { [ "$cur" = "unlimited" ] || [ "$cur" -ge "$want" ] 2>/dev/null; } && ok=y || ok=n ;;
    le) [ "$cur" -le "$want" ] 2>/dev/null && ok=y || ok=n ;;
    eq) [ "$cur" = "$want" ] && ok=y || ok=n ;;
    *)  ok=- ;;
  esac
  if [ "$ok" = y ]; then
    printf "  [OK]     %-38s 현재=%-16s 권장=%s\n" "$label" "$cur" "$want"
    pass=$((pass+1))
  else
    printf "  [변경필요] %-36s 현재=%-16s 권장=%s\n" "$label" "$cur" "$want"
    fail=$((fail+1))
  fi
}

echo "--- 1. 파일 디스크립터 (동시 커넥션 상한)"
check "ulimit -n (soft nofile)"      "$(ulimit -Sn)"                          65536   ge
check "ulimit -n (hard nofile)"      "$(ulimit -Hn)"                          65536   ge
check "fs.file-max (시스템 전체)"     "$(sysctl -n fs.file-max 2>/dev/null)"   1000000 ge
check "fs.nr_open (프로세스 상한)"    "$(sysctl -n fs.nr_open 2>/dev/null)"    1048576 ge

echo ""
echo "--- 2. 프로세스/스레드 (JMeter 1만+ 스레드 대비)"
check "ulimit -u (nproc)"            "$(ulimit -Su)"                                  65536  ge
check "kernel.threads-max"           "$(sysctl -n kernel.threads-max 2>/dev/null)"    100000 ge
check "kernel.pid_max"               "$(sysctl -n kernel.pid_max 2>/dev/null)"        100000 ge
check "vm.max_map_count"             "$(sysctl -n vm.max_map_count 2>/dev/null)"      262144 ge

echo ""
echo "--- 3. 임시 포트 / TIME_WAIT (신규 커넥션 발생 능력)"
portrange=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | tr '\t' '-')
if [ -z "$portrange" ]; then
  printf "  [조회불가] %-36s (이 OS에 없는 키 — RHEL에서 실행할 것)\n" "net.ipv4.ip_local_port_range"
else
  port_lo=${portrange%%-*}
  if [ "${port_lo:-99999}" -le 10240 ] 2>/dev/null; then
    printf "  [OK]     %-38s 현재=%-16s 권장=%s\n" "net.ipv4.ip_local_port_range" "$portrange" "1024-65000"
    pass=$((pass+1))
  else
    printf "  [변경필요] %-36s 현재=%-16s 권장=%s\n" "net.ipv4.ip_local_port_range" "$portrange" "1024-65000"
    fail=$((fail+1))
  fi
fi
check "net.ipv4.tcp_tw_reuse"        "$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null)"      1  ge
check "net.ipv4.tcp_fin_timeout"     "$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null)"  15  le

echo ""
echo "--- 4. 소켓 버퍼 (대용량 응답 수신 대비)"
check "net.core.rmem_max"            "$(sysctl -n net.core.rmem_max 2>/dev/null)"   16777216 ge
check "net.core.wmem_max"            "$(sysctl -n net.core.wmem_max 2>/dev/null)"   16777216 ge

echo ""
echo "--- 5. conntrack (방화벽 켜져 있을 때만 해당)"
ct=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
if [ -n "$ct" ]; then
  check "net.netfilter.nf_conntrack_max" "$ct" 262144 ge
else
  echo "  [정보]    conntrack 모듈 미로드 (방화벽 미사용) — 해당 없음"
fi

echo ""
echo "=== 결과: OK ${pass}건 / 변경필요 ${fail}건 ==="
echo "변경필요 항목은 TUNING.md 6장의 변경 요청서 양식으로 인프라팀에 요청"
