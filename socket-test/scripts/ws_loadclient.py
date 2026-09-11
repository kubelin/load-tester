#!/usr/bin/env python3
# WebSocket 증시 스트리밍 서버 부하/측정 클라이언트 (asyncio, 단일 프로세스 다중 연결).
# 서버 스펙: 접속→connection_established / 'hello N'(N=push간격ms)→stock_stream_started→stock_tick(seq 1..)
#            초과연결은 close 1003 / 'stop'|'bye' 중단 / 60s 무송신 후 서버 PING, PONG 3연속 실패시 1001.
# websockets 라이브러리는 서버 PING에 자동 PONG → 장시간에도 유지됨.
#
# 사용법: ws_loadclient.py <CONNS> <INTERVAL_MS> <DURATION_S> [HOST] [PORT] [PATH] [RAMPUP_S]
#
# 로그 옵션(env):
#   WS_LOG=1        로그 파일 저장 켜기 (기본 0=끔, stdout 출력만)
#   WS_LOGDIR=logs  로그 디렉터리 (기본 ./logs). 실행마다 타임스탬프 파일 2개 생성:
#                     ws_<연결>c_<간격>ms_<시각>.log      요약 리포트
#                     ws_<연결>c_<간격>ms_<시각>.sessions.csv  세션별 상세
import asyncio, sys, re, time, json, os
import websockets

# 느린 소비자 공격: 앞쪽 STALL_N 개 연결은 hello 후 읽기를 멈춘다(소켓 버퍼를 채워
# 서버의 세션별 동기 send 를 블로킹 → 고정 4스레드 executor 고갈 유도). 나머지는 정상 측정.
STALL_N = int(os.environ.get("STALL_N", "0"))

# 로그 저장 토글 (기본 꺼짐). WS_LOG 이 1/true/on/yes 면 켜진다.
LOG_ON  = os.environ.get("WS_LOG", "0").lower() in ("1", "true", "on", "yes")
LOG_DIR = os.environ.get("WS_LOGDIR", "logs")

CONNS   = int(sys.argv[1]) if len(sys.argv) > 1 else 100
INTERVAL= int(sys.argv[2]) if len(sys.argv) > 2 else 1000
DURATION= int(sys.argv[3]) if len(sys.argv) > 3 else 40
HOST    = sys.argv[4] if len(sys.argv) > 4 else "172.30.1.101"
PORT    = int(sys.argv[5]) if len(sys.argv) > 5 else 8080
PATH    = sys.argv[6] if len(sys.argv) > 6 else "/ws/test"
RAMPUP  = float(sys.argv[7]) if len(sys.argv) > 7 else 3.0

URI = "ws://%s:%d%s" % (HOST, PORT, PATH)
SEQ = re.compile(r'"seq"\s*:\s*(\d+)')  # 공백 유무 무관
loop = asyncio.get_event_loop()

async def one(idx, stop_evt, out):
    rec = {"idx": idx, "established": False, "rejected": False, "reject_code": None,
           "first_tick_ms": None, "ticks": 0, "max_seq": 0, "intervals": [],
           "close_code": None, "error": None}
    hello = "hello" if INTERVAL == 1000 else "hello %d" % INTERVAL
    await asyncio.sleep(RAMPUP * idx / max(CONNS, 1))  # 램프업 분산
    try:
        ws = await websockets.connect(URI, ping_interval=None, close_timeout=5, max_size=None)
    except Exception as e:
        rec["error"] = "connect_fail:%s" % e; out.append(rec); return
    try:
        try:
            m0 = await asyncio.wait_for(ws.recv(), timeout=5)
            if '"connection_established"' in m0:
                rec["established"] = True
        except websockets.ConnectionClosed as e:
            rec["rejected"] = True; rec["reject_code"] = e.code; rec["close_code"] = e.code
            return  # finally 가 append 한다 (이중계산 방지)
        t_hello = loop.time()
        await ws.send(hello)
        if idx < STALL_N:
            # 느린 소비자: hello 만 보내고 이후 읽지 않음 → 수신버퍼 참 → 서버 send 블로킹
            rec["stalled"] = True
            try:
                while not stop_evt.is_set():
                    await asyncio.sleep(0.5)
            except Exception:
                pass
            try:
                await ws.close(code=1000)
            except Exception:
                pass
            rec["close_code"] = rec["close_code"] or 1000
            return  # finally 가 append 한다 (이중계산 방지)
        last = None
        while not stop_evt.is_set():
            try:
                m = await asyncio.wait_for(ws.recv(), timeout=3)
            except asyncio.TimeoutError:
                continue
            except websockets.ConnectionClosed as e:
                rec["close_code"] = e.code; break
            if '"stock_tick"' in m:
                now = loop.time()
                if rec["first_tick_ms"] is None:
                    rec["first_tick_ms"] = (now - t_hello) * 1000.0
                if last is not None:
                    rec["intervals"].append((now - last) * 1000.0)
                last = now
                rec["ticks"] += 1
                mm = SEQ.search(m)
                if mm:
                    s = int(mm.group(1))
                    if s > rec["max_seq"]: rec["max_seq"] = s
        try:
            await ws.send("stop")
            await ws.close(code=1000)
            if rec["close_code"] is None: rec["close_code"] = 1000
        except Exception:
            pass
    except Exception as e:
        rec["error"] = str(e)
    finally:
        if rec["close_code"] is None:
            rec["close_code"] = getattr(ws, "close_code", None)
        out.append(rec)

def pct(vals, p):
    if not vals: return None
    s = sorted(vals); k = int(round((p/100.0) * (len(s)-1)))
    return s[k]

async def main():
    stop_evt = asyncio.Event()
    out = []
    tasks = [asyncio.ensure_future(one(i, stop_evt, out)) for i in range(CONNS)]
    await asyncio.sleep(RAMPUP + DURATION)
    stop_evt.set()
    await asyncio.gather(*tasks, return_exceptions=True)

    est = [r for r in out if r["established"]]
    rej = [r for r in out if r["rejected"]]
    errs = [r for r in out if r["error"]]
    all_iv = [v for r in est for v in r["intervals"]]
    firsts = [r["first_tick_ms"] for r in est if r["first_tick_ms"] is not None]
    total_ticks = sum(r["ticks"] for r in est)
    # seq 누락: 세션별 max_seq - 수신틱수 (1..max 단조증가 가정)
    missing = sum(max(0, r["max_seq"] - r["ticks"]) for r in est if r["max_seq"] > 0)
    expected_seq = sum(r["max_seq"] for r in est)
    close_tally = {}
    for r in out:
        c = r["close_code"]; close_tally[c] = close_tally.get(c, 0) + 1

    stalled = sum(1 for r in out if r.get("stalled"))
    # 세션별 p99 분포 → (a)전체 균등 지연 vs (b)일부 세션만 튐 구분
    sp99 = [pct(r["intervals"], 99) for r in est if len(r["intervals"]) >= 5]
    slow = sum(1 for v in sp99 if v is not None and v > 2 * INTERVAL)  # 요청간격 2배 초과 세션

    # 요약 리포트를 줄 단위로 구성 (stdout + 로그 파일 공용)
    L = []
    L.append("================ WS 부하 측정 결과 ================")
    L.append("시각            : %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
    L.append("대상            : %s" % URI)
    L.append("설정            : 연결=%d  간격요청=%dms  지속=%ds  램프업=%.1fs" % (CONNS, INTERVAL, DURATION, RAMPUP))
    L.append("연결 성립       : %d / %d  (느린소비자 %d개 포함)" % (len(est), CONNS, stalled))
    L.append("거절(1003 등)   : %d  %s" % (len(rej), ("codes="+str([r['reject_code'] for r in rej][:5])) if rej else ""))
    L.append("연결오류        : %d  %s" % (len(errs), (errs[0]['error'][:80] if errs else "")))
    L.append("총 수신 tick    : %d" % total_ticks)
    L.append("seq 누락        : %d / 기대 %d  (%.3f%%)" % (missing, expected_seq, (100.0*missing/expected_seq if expected_seq else 0)))
    L.append("첫 hello→첫 tick: p50=%.0fms  p99=%.0fms" % (pct(firsts,50) or 0, pct(firsts,99) or 0))
    L.append("틱 간격(요청 %dms): p50=%.0fms  p99=%.0fms  max=%.0fms" % (
             INTERVAL, pct(all_iv,50) or 0, pct(all_iv,99) or 0, (max(all_iv) if all_iv else 0)))
    L.append("세션별 p99 분포 : p50=%.0f p90=%.0f p99=%.0f max=%.0f ms  (세션 %d개)" % (
             pct(sp99,50) or 0, pct(sp99,90) or 0, pct(sp99,99) or 0, (max(sp99) if sp99 else 0), len(sp99)))
    L.append("느린 세션(p99>2×요청): %d개  → 소수면 (b)느린클라, 전체 균등상승이면 (a)executor포화" % slow)
    L.append("종료 코드 분포  : %s" % close_tally)
    L.append("==================================================")
    json_line = "JSON " + json.dumps({
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "conns": CONNS, "interval_ms": INTERVAL, "duration_s": DURATION,
        "established": len(est), "rejected": len(rej), "errors": len(errs), "stalled": stalled,
        "total_ticks": total_ticks, "seq_missing": missing, "seq_expected": expected_seq,
        "first_tick_p50": pct(firsts,50), "first_tick_p99": pct(firsts,99),
        "iv_p50": pct(all_iv,50), "iv_p99": pct(all_iv,99), "iv_max": (max(all_iv) if all_iv else None),
        "sess_p99_p50": pct(sp99,50), "sess_p99_p99": pct(sp99,99), "sess_p99_max": (max(sp99) if sp99 else None),
        "slow_sessions": slow,
        "close_tally": {str(k): v for k, v in close_tally.items()},
    })

    report = "\n".join(L) + "\n" + json_line
    print(report)

    # 로그 저장 (WS_LOG=1 일 때만)
    if LOG_ON:
        try:
            os.makedirs(LOG_DIR, exist_ok=True)
            base = "ws_%dc_%dms_%s" % (CONNS, INTERVAL, time.strftime("%Y%m%d_%H%M%S"))
            logpath = os.path.join(LOG_DIR, base + ".log")
            with open(logpath, "w") as f:
                f.write(report + "\n")
            # 세션별 상세 CSV (한 줄 = 한 연결)
            csvpath = os.path.join(LOG_DIR, base + ".sessions.csv")
            with open(csvpath, "w") as f:
                f.write("idx,established,rejected,reject_code,stalled,ticks,max_seq,first_tick_ms,iv_p50_ms,iv_p99_ms,close_code,error\n")
                for r in sorted(out, key=lambda x: x.get("idx", 0)):
                    f.write("%d,%d,%d,%s,%d,%d,%d,%s,%s,%s,%s,%s\n" % (
                        r.get("idx", -1), int(r["established"]), int(r["rejected"]),
                        r["reject_code"] if r["reject_code"] is not None else "",
                        int(bool(r.get("stalled"))), r["ticks"], r["max_seq"],
                        ("%.1f" % r["first_tick_ms"]) if r["first_tick_ms"] is not None else "",
                        ("%.1f" % pct(r["intervals"], 50)) if r["intervals"] else "",
                        ("%.1f" % pct(r["intervals"], 99)) if r["intervals"] else "",
                        r["close_code"] if r["close_code"] is not None else "",
                        (r["error"] or "").replace(",", ";")))
            print("로그 저장       : %s , %s" % (logpath, csvpath))
        except Exception as e:
            print("로그 저장 실패   : %s" % e)

loop.run_until_complete(main())
