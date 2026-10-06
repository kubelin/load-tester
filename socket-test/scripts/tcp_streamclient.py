#!/usr/bin/env python3
# TCP 생소켓 시세 수신 클라이언트 — 고정길이(fixed-length) 전문. 구독 전송 → 수신 원문 저장.
# 파싱 없음(그대로 저장). 연결별 시작/종료 시각 기록. 대량 접속 시 저장 OFF.
# python 3.6 / asyncio 표준 라이브러리만 (의존성 없음).
#
# 사용법: tcp_streamclient.py <CONNS> <DURATION_S> <HOST> <PORT> [RAMPUP_S]
#
# ★ 고정길이 (필수):
#   TCP_MSGLEN=200   한 전문의 바이트 수. 이 크기만큼 정확히 읽어 1건으로 센다.
#
# 구독 전문 (택1, 없으면 접속만 하고 수신):
#   TCP_SUB='...'       인라인 구독 문자열. {IDX}=연결번호, {KEY}=종목코드 치환
#   TCP_SUBFILE=sub.txt 파일에서 읽기 (같은 치환)
#   TCP_SUBKEYS='005930,000660'  종목 목록, 연결마다 라운드로빈 → {KEY}
#   TCP_ENCODING=euc-kr 구독 전문 인코딩 (기본 utf-8. 국내 전문은 euc-kr/cp949 흔함)
#
# 저장:
#   TCP_DUMP=1       저장 켜기 (기본 1). ★ 대량접속은 TCP_DUMP=0 으로 끄기
#   DUMP_N=0         0=전체 연결, N=앞쪽 N개 연결만 저장
#   TCP_DUMPDIR=dumps 저장 디렉터리
#   TCP_DUMPFMT=hex  저장 형식: hex(기본, "수신ms\t16진문자") | text(인코딩 디코드) | raw(.bin 원본바이트)
import asyncio, sys, os, time, binascii

CONNS    = int(sys.argv[1]) if len(sys.argv) > 1 else 10
DURATION = int(sys.argv[2]) if len(sys.argv) > 2 else 60
HOST     = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
PORT     = int(sys.argv[4]) if len(sys.argv) > 4 else 9000
RAMPUP   = float(sys.argv[5]) if len(sys.argv) > 5 else 3.0

MSGLEN   = int(os.environ.get("TCP_MSGLEN", "0"))
if MSGLEN <= 0:
    print("오류: TCP_MSGLEN(고정 전문 길이, 바이트)을 지정해야 한다. 예: TCP_MSGLEN=200"); sys.exit(1)

TCP_DUMP = os.environ.get("TCP_DUMP", "1").lower() in ("1", "true", "on", "yes")
DUMP_N   = int(os.environ.get("DUMP_N", "0"))
DUMP_DIR = os.environ.get("TCP_DUMPDIR", "dumps")
DUMP_FMT = os.environ.get("TCP_DUMPFMT", "hex").lower()
ENCODING = os.environ.get("TCP_ENCODING", "utf-8")
SUB_INLINE = os.environ.get("TCP_SUB", "")
SUB_FILE   = os.environ.get("TCP_SUBFILE", "")
SUB_KEYS   = [k.strip() for k in os.environ.get("TCP_SUBKEYS", "").split(",") if k.strip()]

SUB_TEMPLATE = ""
if SUB_FILE:
    try:
        SUB_TEMPLATE = open(SUB_FILE, encoding=ENCODING).read()
    except Exception as e:
        print("구독 파일 읽기 실패: %s" % e); sys.exit(1)
elif SUB_INLINE:
    SUB_TEMPLATE = SUB_INLINE

def sub_bytes(idx):
    """연결 idx 용 구독 전문(bytes). 템플릿 없으면 None."""
    if not SUB_TEMPLATE:
        return None
    key = SUB_KEYS[idx % len(SUB_KEYS)] if SUB_KEYS else ""
    s = SUB_TEMPLATE.replace("{IDX}", str(idx)).replace("{KEY}", key)
    return s.encode(ENCODING, "replace")

def dumps_this(idx):
    return TCP_DUMP and (DUMP_N == 0 or idx < DUMP_N)

try:
    loop = asyncio.get_event_loop()
except RuntimeError:                      # python 3.12+
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

async def one(idx, out):
    rec = {"idx": idx, "established": False, "t_start": None, "t_first": None,
           "t_last": None, "t_end": None, "records": 0, "bytes": 0,
           "close": None, "error": None, "dumped": False}
    await asyncio.sleep(RAMPUP * idx / max(CONNS, 1))
    f = None
    writer = None
    try:
        try:
            reader, writer = await asyncio.open_connection(HOST, PORT)
        except Exception as e:
            rec["error"] = "connect_fail:%s" % e; return
        sub = sub_bytes(idx)
        rec["t_start"] = time.time()          # ★ 시작시간 (구독 직후)
        if sub is not None:
            writer.write(sub)
            await writer.drain()
        rec["established"] = True
        if dumps_this(idx):
            try:
                os.makedirs(DUMP_DIR, exist_ok=True)
                if DUMP_FMT == "raw":
                    f = open(os.path.join(DUMP_DIR, "conn_%05d.bin" % idx), "wb")
                else:
                    f = open(os.path.join(DUMP_DIR, "conn_%05d.dat" % idx), "w")
                    f.write("# start %s conn=%d key=%s %s:%d msglen=%d fmt=%s\n" % (
                        time.strftime("%Y-%m-%dT%H:%M:%S"), idx,
                        (SUB_KEYS[idx % len(SUB_KEYS)] if SUB_KEYS else ""),
                        HOST, PORT, MSGLEN, DUMP_FMT))
                rec["dumped"] = True
            except Exception as e:
                rec["error"] = "dump_open_fail:%s" % e
        # 고정길이 수신 루프 — readexactly 로 정확히 MSGLEN 바이트씩 = 1전문
        while True:
            try:
                data = await reader.readexactly(MSGLEN)
            except asyncio.IncompleteReadError:
                rec["close"] = "eof"; break      # 서버가 끊음 (부분수신 포함)
            except asyncio.CancelledError:
                rec["close"] = "duration"; raise # 시간종료 → 상위에서 취소
            now = time.time()
            if rec["t_first"] is None:
                rec["t_first"] = now
            rec["t_last"] = now
            rec["records"] += 1
            rec["bytes"] += MSGLEN
            if f is not None:
                if DUMP_FMT == "raw":
                    f.write(data)
                elif DUMP_FMT == "text":
                    txt = data.decode(ENCODING, "replace").replace("\n", " ")
                    f.write("%d\t%s\n" % (int(now * 1000), txt))
                else:  # hex
                    f.write("%d\t%s\n" % (int(now * 1000), binascii.hexlify(data).decode()))
    except asyncio.CancelledError:
        pass
    except Exception as e:
        rec["error"] = str(e)
    finally:
        rec["t_end"] = time.time()            # ★ 종료시간
        if writer is not None:
            try: writer.close()
            except Exception: pass
        if f is not None:
            try:
                if DUMP_FMT != "raw":
                    f.write("# end %s records=%d bytes=%d\n" % (
                        time.strftime("%Y-%m-%dT%H:%M:%S"), rec["records"], rec["bytes"]))
                f.close()
            except Exception: pass
        out.append(rec)

def fmt_ts(t):
    if not t: return ""
    return time.strftime("%H:%M:%S", time.localtime(t)) + (".%03d" % int((t % 1) * 1000))

async def main():
    out = []
    run_start = time.time()
    tasks = [asyncio.ensure_future(one(i, out)) for i in range(CONNS)]
    await asyncio.sleep(RAMPUP + DURATION)
    for t in tasks:
        t.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    run_end = time.time()

    est = [r for r in out if r["established"]]
    errs = [r for r in out if r["error"]]
    total_rec = sum(r["records"] for r in est)
    total_bytes = sum(r["bytes"] for r in est)
    dumped = sum(1 for r in out if r["dumped"])
    dur = (run_end - run_start) or 1
    close_tally = {}
    for r in out:
        c = r["close"]; close_tally[c] = close_tally.get(c, 0) + 1

    print("================ TCP 시세수신 결과 ================")
    print("대상            : %s:%d  (고정전문 %d바이트)" % (HOST, PORT, MSGLEN))
    print("전체 시작/종료  : %s ~ %s  (%.1fs)" % (
        time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(run_start)),
        time.strftime("%H:%M:%S", time.localtime(run_end)), dur))
    print("연결 성립       : %d / %d" % (len(est), CONNS))
    print("연결오류        : %d  %s" % (len(errs), (errs[0]['error'][:80] if errs else "")))
    print("총 수신 전문    : %d  (합산 %.0f 건/s)" % (total_rec, total_rec / dur))
    print("총 수신 바이트  : %d  (%.1f MB)" % (total_bytes, total_bytes / 1048576.0))
    print("원문 저장       : %s  (저장 연결 %d개, 형식 %s, 디렉터리 %s)" % (
        "ON" if TCP_DUMP else "OFF (대량모드)", dumped, DUMP_FMT, DUMP_DIR if dumped else "-"))
    print("종료 사유 분포  : %s" % close_tally)
    print("==================================================")

    try:
        os.makedirs(DUMP_DIR, exist_ok=True)
        csvp = os.path.join(DUMP_DIR, "tcp_sessions_%s.csv" % time.strftime("%Y%m%d_%H%M%S"))
        with open(csvp, "w") as cf:
            cf.write("idx,established,start_time,first_msg_time,last_msg_time,end_time,records,bytes,close,error\n")
            for r in sorted(out, key=lambda x: x["idx"]):
                cf.write("%d,%d,%s,%s,%s,%s,%d,%d,%s,%s\n" % (
                    r["idx"], int(r["established"]),
                    fmt_ts(r["t_start"]), fmt_ts(r["t_first"]), fmt_ts(r["t_last"]), fmt_ts(r["t_end"]),
                    r["records"], r["bytes"], r["close"] or "", (r["error"] or "").replace(",", ";")))
        print("세션 요약 CSV   : %s" % csvp)
    except Exception as e:
        print("CSV 저장 실패   : %s" % e)

loop.run_until_complete(main())
