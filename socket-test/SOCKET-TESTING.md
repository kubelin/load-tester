# 소켓 부하·수신 테스트 가이드 (WebSocket / TCP)

증시 스트리밍처럼 **연결을 유지하며 데이터를 받는** 시스템의 부하·수신 테스트 모음.
HTTP 킷(루트의 TESTING.md 등)과 별개로 이 `socket-test/` 안에서 완결된다.

## 도구 지도 — 뭘 언제 쓰나

| 목적 | 도구 | 프로토콜 |
|---|---|---|
| **정밀 측정** (seq 누락·틱간격 p99) | `ws_loadclient.py` | WebSocket |
| **수신 원문 저장** (구독→받아서 그대로 쌓기) | `ws_streamclient.py` | WebSocket |
| **고정길이 전문 수신·저장** | `tcp_streamclient.py` | 생 TCP |
| **대량 부하·서버 한계** (한 박스 멀티) | `run-ws-multi.sh` | WebSocket |
| **대량 부하·서버 한계** (여러 발생기) | `run-ws-swarm.sh` | WebSocket |
| **대규모 결과 합산·판정** | `ws_aggregate.py` | — |
| **JMeter 플랜** (연결+구독+수신) | `ws-load.jmx` + 플러그인 | WebSocket |

**고르는 기준:**
```
데이터 정확성·지연 품질 검증   → ws_loadclient.py (측정 전용)
받은 데이터를 파일로 보관       → ws_streamclient.py (WS) / tcp_streamclient.py (TCP)
서버 연결 한계 찾기 (대규모)    → run-ws-multi(한대) / run-ws-swarm(여러대) + ws_aggregate
```

---

## 1. 측정 모드 — ws_loadclient.py

seq 누락, hello→첫틱 지연, 틱 간격 p50/p99, 느린소비자 공격까지. **소수 연결로 품질 검증**.

```bash
pip install --user "websockets==8.1"
python3 scripts/ws_loadclient.py 500 100 120 <서버IP> 8080 /ws/test 8
#   <연결> <간격ms> <지속s> <호스트> <포트> <경로> <램프s>
WS_LOG=1 python3 scripts/ws_loadclient.py ...   # 결과 파일 저장
STALL_N=250 python3 scripts/ws_loadclient.py ... # 느린소비자 250개
```

---

## 2. 수신 저장 모드 — 구독 후 받은 데이터를 그대로 쌓기

### 2-A. WebSocket (JSON 구독)

```bash
WS_SUB='{"header":{"tr_id":"H0STCNT0"},"body":{"input":{"tr_key":"{KEY}"}}}' \
WS_SUBKEYS='005930,000660' \
./scripts/run-ws-stream.sh 20 <서버IP> 8080 /ws/quote 120
```
- `{KEY}`=종목(라운드로빈), `{IDX}`=연결번호 치환. 구독 JSON은 시스템마다 자유롭게.
- 대량은 `WS_DUMP=0`(저장 OFF), 표본만은 `DUMP_N=50`.

### 2-B. 생 TCP (고정길이 전문)

```bash
TCP_MSGLEN=200 TCP_SUB='SUB|{KEY}' TCP_SUBKEYS='005930' TCP_DUMPFMT=text \
TCP_ENCODING=euc-kr \
./scripts/run-tcp-stream.sh 20 <서버IP> 9000 120
```
- `TCP_MSGLEN`으로 전문 길이 지정 → 정확히 그만큼씩 읽어 1건. 파싱 없음.
- 저장 형식: `hex`(바이너리 안전) / `text`(디코드) / `raw`(.bin 원본).
- 국내 FEP 전문은 `TCP_ENCODING=euc-kr` 흔함.

**저장 결과 (공통)** — `dumps/`:
```
conn_<idx>.dat|.bin   연결별 수신 원문 (시작/종료 시각 헤더 포함)
*_sessions_*.csv      연결별 시작/첫수신/마지막/종료 시각 + 수신 개수·바이트
```

---

## 3. 대량 부하 — 서버 실한계 찾기

단일 발생기는 발생기가 먼저 포화된다. 서버 한계를 보려면 분산한다.

```bash
# 한 박스 멀티 프로세스 (Python은 프로세스당 1코어)
./scripts/run-ws-multi.sh 20000 <서버IP> 8080 /ws/test 1000 180 8

# 여러 발생기 (서버가 여러 IP에서 연결받음)
./scripts/run-ws-swarm.sh "load@10.0.0.11,load@10.0.0.12" 40000 <서버IP> 8080 /ws/test 1000 180

# 사다리로 한계 탐색
for N in 20000 40000 60000; do ./scripts/run-ws-multi.sh $N <서버IP> 8080 /ws/test 1000 120 8; done
```

**서버 한계 판정** (`ws_aggregate.py`가 자동 출력):
- 거절(close 1003) 증가 → 연결 상한 / seq 누락 → 처리 한계 / 틱간격 p99≫요청 → cadence 한계
- 거절·누락 없이 오류만 → **발생기 포화** → 스웜으로 호스트 더 늘려 재확인

---

## 4. 발생기 한계 — 알아둘 것

| 자원 | 상한 | 대응 |
|---|---|---|
| **임시 포트** | 단일 타겟 ~16k(기본)~32k | 6만+ 연결은 **스웜 필수** (여러 발생기) |
| **FD** | `ulimit -n` | 65536+ 로 (연결당 1개, 덤프 시 +1) |
| **메모리** | 연결당 ~164KB | 5만 연결 ≈ 8GB |
| **CPU** | 프로세스당 1코어(Python) | 멀티프로세스(run-ws-multi) |

WebSocket은 세션이 포트를 끝까지 점유하므로 HTTP보다 포트 압박이 크다. 커널 튜닝은
루트 `TUNING.md` 1장(발생기) 참고.

---

## 5. 프로토콜 확장

- **WebSocket 구독 형식** — `WS_SUB`에 아무 JSON이나. 시스템마다 다르면 `sub_*.json` 파일로 분리.
- **TCP 가변 길이** — 지금은 한 실행에 한 고정길이. 전문 길이가 헤더에 들어있는 가변
  프레이밍이 필요하면 헤더 위치·형식(바이트 오프셋, ASCII/바이너리)을 주면 추가.
- **인증/로그인 전문** — 접속 후 구독 전에 로그인이 필요하면 알려주면 선행 전송 추가.
