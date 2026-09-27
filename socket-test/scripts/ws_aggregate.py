#!/usr/bin/env python3
# ws_aggregate.py — 여러 ws_loadclient 실행 결과(.out)를 합산하고 서버 한계 신호를 판정한다.
# 각 .out 파일에서 "JSON {...}" 라인을 찾아 파싱. 프로세스/호스트 몇 개든 합쳐준다.
#
# 사용법: ws_aggregate.py <간격ms> <file1.out> [file2.out ...]
#   간격ms 는 틱 요청 간격(판정 기준). 파일은 각 발생기 프로세스의 stdout 캡처.
import sys, json, re

if len(sys.argv) < 3:
    print("사용법: ws_aggregate.py <간격ms> <결과.out ...>"); sys.exit(1)

INTERVAL = int(sys.argv[1])
files = sys.argv[2:]
JLINE = re.compile(r'^JSON (\{.*\})\s*$')

rows = []
for f in files:
    found = None
    try:
        for line in open(f):
            m = JLINE.match(line.strip())
            if m:
                found = json.loads(m.group(1))
    except Exception as e:
        print("  [읽기실패] %s: %s" % (f, e)); continue
    if found:
        found["_src"] = f
        rows.append(found)
    else:
        print("  [JSON없음] %s (실행 실패 가능 — 파일 확인)" % f)

if not rows:
    print("합산할 결과 없음"); sys.exit(1)

def s(key): return sum(r.get(key, 0) or 0 for r in rows)
def worst(key):
    vals = [r.get(key) for r in rows if r.get(key) is not None]
    return max(vals) if vals else None
def best(key):
    vals = [r.get(key) for r in rows if r.get(key) is not None]
    return min(vals) if vals else None

est = s("established"); rej = s("rejected"); err = s("errors")
ticks = s("total_ticks"); miss = s("seq_missing"); exp = s("seq_expected")
dur = max((r.get("duration_s", 0) for r in rows), default=1) or 1

# 종료코드 합산
close = {}
for r in rows:
    for k, v in (r.get("close_tally") or {}).items():
        close[k] = close.get(k, 0) + v

print("=" * 60)
print("WS 분산 부하 합산 결과  (발생 소스 %d개)" % len(rows))
print("=" * 60)
print("총 연결 성립     : %d" % est)
print("총 거절          : %d   %s" % (rej, "← 서버 커넥션 상한 도달!" if rej else ""))
print("총 연결오류      : %d   %s" % (err, "← 발생기 포화 or 서버 accept 한계 (아래 판정)" if err else ""))
print("총 수신 tick     : %d  (합산 %.0f tick/s)" % (ticks, ticks / dur))
print("seq 누락         : %d / 기대 %d  (%.3f%%)  %s" % (
    miss, exp, (100.0 * miss / exp if exp else 0), "← 서버가 데이터 유실!" if miss else ""))
print("틱 간격 p99      : 최악소스 %s ms  (요청 %dms)" % (worst("iv_p99"), INTERVAL))
print("첫틱 지연 p99    : 최악소스 %s ms" % worst("first_tick_p99"))
print("종료 코드 분포   : %s" % close)
print("-" * 60)

# 소스별 표
print("%-28s %8s %6s %8s" % ("소스", "성립", "거절", "iv_p99"))
for r in sorted(rows, key=lambda x: x["_src"]):
    src = r["_src"]
    if len(src) > 27: src = "..." + src[-24:]
    print("%-28s %8d %6d %8s" % (src, r.get("established", 0), r.get("rejected", 0), r.get("iv_p99")))
print("-" * 60)

# 서버 한계 판정
print("판정:")
verdict = []
if rej > 0:
    verdict.append("  • 거절 %d건 → 서버가 커넥션 상한에서 거절 시작 = **연결 한계 발견**" % rej)
if miss > 0:
    verdict.append("  • seq 누락 %d건 → 서버가 부하에서 데이터 유실 = **처리 한계**" % miss)
ivp = worst("iv_p99")
if ivp is not None and ivp > 2 * INTERVAL:
    verdict.append("  • 틱 간격 p99(%sms)이 요청(%dms)의 2배 초과 → 서버 스트리밍 지연 = **cadence 한계**" % (ivp, INTERVAL))
if err > 0 and rej == 0 and miss == 0:
    verdict.append("  • 오류 %d건인데 거절·누락 없음 → 발생기측(포트/CPU) 포화 의심. 소스를 더 늘려 재확인" % err)
if not verdict:
    verdict.append("  • 거절 0 · 누락 0 · 지연 정상 → 서버 아직 여유. 연결수를 더 올려 한계까지 밀 것")
print("\n".join(verdict))
print("=" * 60)
