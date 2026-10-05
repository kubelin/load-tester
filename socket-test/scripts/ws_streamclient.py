#!/usr/bin/env python3
# WebSocket 시세 수신 클라이언트 — JSON 구독요청 전송 → 수신 데이터를 "파싱 없이 그대로" 저장.
# 연결별 시작/종료 시각 기록. 대량 접속 시 저장 끄기(WS_DUMP=0).
# python 3.6 / websockets 8.1 호환.
#
# 사용법: ws_streamclient.py <CONNS> <DURATION_S> [HOST] [PORT] [PATH] [RAMPUP_S]
#
# 구독 메시지 (택1, 없으면 접속만 하고 수신):
#   WS_SUB='{"header":{...},"body":{...}}'   인라인 JSON. {IDX}=연결번호, {KEY}=종목코드로 치환
#   WS_SUBFILE=sub.json                       파일에서 읽기 (같은 치환 적용)
#   WS_SUBKEYS='005930,000660,035720'         종목코드 목록 — 연결마다 하나씩 라운드로빈 ({KEY})
#
# 저장 옵션:
#   WS_DUMP=1        수신 원문 저장 켜기 (기본 1=켬). ★ 대량접속은 WS_DUMP=0 으로 끄기
#   DUMP_N=0         0=전체 연결 저장, N=앞쪽 N개 연결만 저장 (대량 중 표본만 보고 싶을 때)
#   WS_DUMPDIR=dumps 저장 디렉터리 (연결마다 conn_<idx>.dat)
import asyncio, sys, time, os, json
import websockets

CONNS    = int(sys.argv[1]) if len(sys.argv) > 1 else 10
DURATION = int(sys.argv[2]) if len(sys.argv) > 2 else 60
HOST     = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
PORT     = int(sys.argv[4]) if len(sys.argv) > 4 else 8080
PATH     = sys.argv[5] if len(sys.argv) > 5 else "/ws/test"
RAMPUP   = float(sys.argv[6]) if len(sys.argv) > 6 else 3.0

WS_DUMP  = os.environ.get("WS_DUMP", "1").lower() in ("1", "true", "on", "yes")
DUMP_N   = int(os.environ.get("DUMP_N", "0"))          # 0=전체
DUMP_DIR = os.environ.get("WS_DUMPDIR", "dumps")
SUB_INLINE = os.environ.get("WS_SUB", "")
SUB_FILE   = os.environ.get("WS_SUBFILE", "")
SUB_KEYS   = [k.strip() for k in os.environ.get("WS_SUBKEYS", "").split(",") if k.strip()]

URI = "ws://%s:%d%s" % (HOST, PORT, PATH)

# 구독 메시지 템플릿 로드 (파일 > 인라인)
SUB_TEMPLATE = ""
if SUB_FILE:
    try:
        SUB_TEMPLATE = open(SUB_FILE).read().strip()
    except Exception as e:
        print("구독 파일 읽기 실패: %s" % e); sys.exit(1)
elif SUB_INLINE:
    SUB_TEMPLATE = SUB_INLINE

def sub_for(idx):
    """연결 idx 용 구독 메시지 — {IDX}/{KEY} 치환. 템플릿 없으면 None(구독 안 함)."""
    if not SUB_TEMPLATE:
        return None
    key = SUB_KEYS[idx % len(SUB_KEYS)] if SUB_KEYS else ""
    return SUB_TEMPLATE.replace("{IDX}", str(idx)).replace("{KEY}", key)

def dumps_this(idx):
    return WS_DUMP and (DUMP_N == 0 or idx < DUMP_N)

try:
    loop = asyncio.get_event_loop()
except RuntimeError:                      # python 3.12+ : 실행 루프 없을 때
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

async def one(idx, stop_evt, out):
    rec = {"idx": idx, "established": False, "rejected": False, "reject_code": None,
           "t_connect": None, "t_start": None, "t_first": None, "t_last": None, "t_end": None,
           "msgs": 0, "bytes": 0, "close_code": None, "error": None, "dumped": False}
    await asyncio.sleep(RAMPUP * idx / max(CONNS, 1))  # 램프업 분산
    f = None
    try:
        rec["t_connect"] = time.time()
        try:
            ws = await websockets.connect(URI, ping_interval=None, close_timeout=5, max_size=None)
        except Exception as e:
            rec["error"] = "connect_fail:%s" % e; return
        # 구독 요청 전송 (JSON)
        sub = sub_for(idx)
        rec["t_start"] = time.time()          # ★ 시작시간 (구독 직후)
        if sub is not None:
            try:
                await ws.send(sub)
            except websockets.ConnectionClosed as e:
                rec["rejected"] = True; rec["reject_code"] = e.code; rec["close_code"] = e.code
                return
        rec["established"] = True
        # 덤프 파일 열기
        if dumps_this(idx):
            try:
                os.makedirs(DUMP_DIR, exist_ok=True)
                f = open(os.path.join(DUMP_DIR, "conn_%05d.dat" % idx), "w")
                f.write("# start %s conn=%d key=%s uri=%s\n" % (
                    time.strftime("%Y-%m-%dT%H:%M:%S"), idx,
                    (SUB_KEYS[idx % len(SUB_KEYS)] if SUB_KEYS else ""), URI))
                rec["dumped"] = True
            except Exception as e:
                rec["error"] = "dump_open_fail:%s" % e
        # 수신 루프 — 파싱 없이 그대로
        while not stop_evt.is_set():
            try:
                m = await asyncio.wait_for(ws.recv(), timeout=3)
            except asyncio.TimeoutError:
                continue
            except websockets.ConnectionClosed as e:
                rec["close_code"] = e.code; break
            now = time.time()
            if rec["t_first"] is None:
                rec["t_first"] = now
            rec["t_last"] = now
            rec["msgs"] += 1
            rec["bytes"] += len(m) if isinstance(m, (str, bytes)) else 0
            if f is not None:
                # 수신시각(ms) + 원문 한 줄 (그대로). 개행 포함 메시지는 공백 치환.
                line = m if isinstance(m, str) else m.decode("utf-8", "replace")
                f.write("%d\t%s\n" % (int(now * 1000), line.replace("\n", " ")))
        try:
            await ws.close(code=1000)
            if rec["close_code"] is None: rec["close_code"] = 1000
        except Exception:
            pass
    except Exception as e:
        rec["error"] = str(e)
    finally:
        rec["t_end"] = time.time()            # ★ 종료시간
        if f is not None:
            try:
                f.write("# end %s msgs=%d bytes=%d\n" % (
                    time.strftime("%Y-%m-%dT%H:%M:%S"), rec["msgs"], rec["bytes"]))
                f.close()
            except Exception:
                pass
        out.append(rec)

def fmt_ts(t):
    return time.strftime("%H:%M:%S", time.localtime(t)) + (".%03d" % int((t % 1) * 1000)) if t else ""

async def main():
    stop_evt = asyncio.Event()
    out = []
    run_start = time.time()
    tasks = [asyncio.ensure_future(one(i, stop_evt, out)) for i in range(CONNS)]
    await asyncio.sleep(RAMPUP + DURATION)
    stop_evt.set()
    await asyncio.gather(*tasks, return_exceptions=True)
    run_end = time.time()

    est = [r for r in out if r["established"]]
    rej = [r for r in out if r["rejected"]]
    errs = [r for r in out if r["error"]]
    total_msgs = sum(r["msgs"] for r in est)
    total_bytes = sum(r["bytes"] for r in est)
    dumped = sum(1 for r in out if r["dumped"])
    dur = (run_end - run_start) or 1

    L = []
    L.append("================ WS 시세수신 결과 ================")
    L.append("대상            : %s" % URI)
    L.append("전체 시작/종료  : %s ~ %s  (%.1fs)" % (
        time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(run_start)),
        time.strftime("%H:%M:%S", time.localtime(run_end)), dur))
    L.append("연결 성립       : %d / %d" % (len(est), CONNS))
    L.append("거절            : %d  %s" % (len(rej), str([r['reject_code'] for r in rej][:5]) if rej else ""))
    L.append("연결오류        : %d  %s" % (len(errs), (errs[0]['error'][:80] if errs else "")))
    L.append("총 수신 메시지  : %d  (합산 %.0f msg/s)" % (total_msgs, total_msgs / dur))
    L.append("총 수신 바이트  : %d  (%.1f MB)" % (total_bytes, total_bytes / 1048576.0))
    L.append("원문 저장       : %s  (저장 연결 %d개, 디렉터리 %s)" % (
        "ON" if WS_DUMP else "OFF (대량모드)", dumped, DUMP_DIR if dumped else "-"))
    L.append("종료 코드 분포  : %s" % _tally(out))
    L.append("==================================================")
    json_line = "JSON " + json.dumps({
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(run_start)),
        "uri": URI, "conns": CONNS, "duration_s": DURATION,
        "established": len(est), "rejected": len(rej), "errors": len(errs),
        "total_msgs": total_msgs, "total_bytes": total_bytes, "dumped": dumped,
        "msg_rate": total_msgs / dur,
    })
    print("\n".join(L) + "\n" + json_line)

    # 연결별 시작/종료/수신 요약 CSV (항상 저장 — 가벼움, 대량모드에서도 남김)
    try:
        os.makedirs(DUMP_DIR, exist_ok=True)
        csvp = os.path.join(DUMP_DIR, "sessions_%s.csv" % time.strftime("%Y%m%d_%H%M%S"))
        with open(csvp, "w") as cf:
            cf.write("idx,established,rejected,start_time,first_msg_time,last_msg_time,end_time,msgs,bytes,close_code,error\n")
            for r in sorted(out, key=lambda x: x["idx"]):
                cf.write("%d,%d,%d,%s,%s,%s,%s,%d,%d,%s,%s\n" % (
                    r["idx"], int(r["established"]), int(r["rejected"]),
                    fmt_ts(r["t_start"]), fmt_ts(r["t_first"]), fmt_ts(r["t_last"]), fmt_ts(r["t_end"]),
                    r["msgs"], r["bytes"],
                    r["close_code"] if r["close_code"] is not None else "",
                    (r["error"] or "").replace(",", ";")))
        print("세션 요약 CSV   : %s" % csvp)
    except Exception as e:
        print("CSV 저장 실패   : %s" % e)

def _tally(out):
    t = {}
    for r in out:
        c = r["close_code"]; t[c] = t.get(c, 0) + 1
    return t

loop.run_until_complete(main())
