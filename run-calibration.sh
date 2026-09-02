#!/bin/bash
# JMeter load-generator calibration: find this Mac's limits before real tests.
# Stage 1 (200 threads, no think time)  -> max RPS ceiling
# Stages 2-5 (1000..5000 threads, 1s think time) -> thread-count ceiling
set -uo pipefail
cd "$(dirname "$0")"

ulimit -n 65536
echo "ulimit -n: $(ulimit -n)"

mkdir -p results

echo "building dummy server..."
(cd server && go build -o dummy-server main.go) || exit 1

GOMAXPROCS=4 ./server/dummy-server >results/server.log 2>&1 &
SERVER_PID=$!
sleep 1
if ! curl -s http://127.0.0.1:18080/ok | grep -q OK; then
  echo "dummy server failed to start"; cat results/server.log; exit 1
fi
echo "dummy server up (pid $SERVER_PID, GOMAXPROCS=4)"

cleanup() { kill "$SERVER_PID" 2>/dev/null; }
trap cleanup EXIT

STAGES=("200 0" "1000 1000" "2000 1000" "3000 1000" "5000 1000")

for stage in "${STAGES[@]}"; do
  read -r T THINK <<< "$stage"
  RAMP=$(( T / 100 )); [ "$RAMP" -lt 5 ] && RAMP=5
  DUR=$(( RAMP + 45 ))
  TAG="t${T}_think${THINK}"
  echo ""
  echo "=== Stage $TAG: threads=$T think=${THINK}ms ramp=${RAMP}s dur=${DUR}s ==="

  rm -f "results/result_$TAG.jtl" "results/cpu_$TAG.log"

  # CPU sampler: jmeter %cpu, server %cpu, system idle% every 5s
  (
    while true; do
      scpu=$(ps -o %cpu= -p "$SERVER_PID" 2>/dev/null | tr -d ' ')
      jpid=$(pgrep -f ApacheJMeter | head -1)
      jcpu=""
      [ -n "$jpid" ] && jcpu=$(ps -o %cpu= -p "$jpid" 2>/dev/null | tr -d ' ')
      idle=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/{gsub("%","",$7); print $7}')
      echo "$(date +%s) jmeter=${jcpu:-0} server=${scpu:-0} idle=${idle:-?}" >> "results/cpu_$TAG.log"
      sleep 5
    done
  ) &
  CPU_PID=$!

  JVM_ARGS="-Xms2g -Xmx8g -Xss256k" jmeter -n -t calibration.jmx \
    -Jthreads="$T" -Jrampup="$RAMP" -Jduration="$DUR" -Jthinkms="$THINK" \
    -l "results/result_$TAG.jtl" -j "results/jmeter_$TAG.log" \
    2>&1 | tee "results/summary_$TAG.txt" | grep -E "summary|Err" || true

  kill "$CPU_PID" 2>/dev/null
  wait "$CPU_PID" 2>/dev/null
  sleep 5
done

echo ""
echo "===================== CALIBRATION RESULT ====================="
python3 - <<'EOF'
import csv, glob, os, re

def cpu_stats(tag):
    path = f'results/cpu_{tag}.log'
    jm, idle = [], []
    if os.path.exists(path):
        for line in open(path):
            m = re.search(r'jmeter=([\d.]+).*idle=([\d.]+)', line)
            if m:
                jm.append(float(m.group(1))); idle.append(float(m.group(2)))
    return (max(jm) if jm else 0, min(idle) if idle else -1)

order = []
for f in glob.glob('results/result_*.jtl'):
    tag = os.path.basename(f)[7:-4]
    t = int(re.search(r't(\d+)_', tag).group(1))
    think = int(re.search(r'think(\d+)', tag).group(1))
    order.append((think > 0, t, tag, f))
order.sort()

print(f"{'stage':<16}{'samples':>9}{'RPS':>9}{'err%':>7}{'avg':>6}{'p95':>6}{'p99':>6}"
      f"{'jm-cpu%':>9}{'idle%':>7}")
for _, _, tag, f in order:
    el, ts, err, n = [], [], 0, 0
    with open(f) as fh:
        r = csv.reader(fh)
        head = next(r)
        i_el, i_su, i_ts = head.index('elapsed'), head.index('success'), head.index('timeStamp')
        for row in r:
            try:
                el.append(int(row[i_el])); ts.append(int(row[i_ts])); n += 1
                if row[i_su] != 'true': err += 1
            except (ValueError, IndexError):
                pass
    if not n:
        print(f"{tag:<16}  (no samples)"); continue
    el.sort()
    dur = (max(ts) - min(ts)) / 1000 or 1
    p = lambda q: el[min(n - 1, int(n * q))]
    jcpu, idle = cpu_stats(tag)
    print(f"{tag:<16}{n:>9}{n/dur:>9.0f}{100*err/n:>7.2f}{sum(el)/n:>6.1f}"
          f"{p(0.95):>6}{p(0.99):>6}{jcpu:>9.0f}{idle:>7.1f}")
print()
print("jm-cpu%: jmeter process peak (100% = 1 core, machine total = 1200%)")
print("idle%:   system-wide minimum idle during stage")
EOF
