# socket-test — WebSocket 부하/한계 테스트

증시 스트리밍 WebSocket 서버(`hello` 트리거 → `stock_tick` 스트리밍)에 대한 부하·한계 테스트 세트.
JMeter 플랜과 정밀 측정용 asyncio 클라이언트, 그리고 결과 리포트가 들어있다.

## 구성

| 파일 | 용도 |
|---|---|
| `ws-load.jmx` | JMeter WebSocket 부하 플랜 (연결 유지 + 구독 메시지 + 수신) |
| `lib/jmeter-websocket-samplers-1.2.10.jar` | JMeter WebSocket Samplers 플러그인 (의존성 없는 단일 JAR) |
| `scripts/run-ws.sh` | JMeter 실행 래퍼 |
| `scripts/ws_loadclient.py` | asyncio 측정 클라이언트 (seq 누락 / 틱간격 p50·p99 / 느린소비자 모드) |
| `ws-loadtest-report.html` | 테스트 결과 리포트 (브라우저로 열기) |

> JMeter 코어에는 WebSocket 기능이 없다. `lib/jmeter-websocket-samplers-*.jar` 를
> `$JMETER_HOME/lib/ext/` 에 복사해야 플랜이 로드된다.

## 프로토콜

```
접속 → connection_established
"hello N" 전송 (N = push 간격 ms, 50~60000) → stock_stream_started → stock_tick(seq 1..)
"stop" / "bye" → 중단
```

## 실행

### A) JMeter 플랜

```bash
# 플러그인 설치
cp lib/jmeter-websocket-samplers-*.jar "$JMETER_HOME/lib/ext/"

# 실행: <연결수> <호스트> [포트] [경로] [지속초] [간격ms]
./scripts/run-ws.sh 500 <서버IP> 8080 /ws/test 120 0

# 접속 즉시 서버가 push → 구독 불필요:  SUBSCRIBE=false ./scripts/run-ws.sh ...
# 수신 데이터 검증:                     EXPECT='"stock_tick"' ./scripts/run-ws.sh ...
```

### B) asyncio 측정 클라이언트 (권장 — 정밀 지표)

```bash
pip install --user "websockets==8.1"   # python 3.6 호환
# <연결> <간격ms> <지속s> [호스트] [포트] [경로] [램프s]
python3 scripts/ws_loadclient.py 500 100 120 <서버IP> 8080 /ws/test 8

# 느린-소비자(executor 블로킹) 테스트: 앞쪽 N개 연결이 hello 후 읽기 중단
STALL_N=250 python3 scripts/ws_loadclient.py 300 50 180 <서버IP> 8080 /ws/test 15
```

출력: 연결 성립/거절, seq 누락, hello→첫틱 지연 p50/p99, 틱 간격 p50/p99, 세션별 p99 분포, 종료코드 분포.

#### 로그 저장 (env 옵션 · 기본 꺼짐)

```bash
WS_LOG=1 python3 scripts/ws_loadclient.py 2000 1000 60 <서버IP> 8080 /ws/test 15
# → logs/ 에 실행마다 2개 생성:
#     ws_<연결>c_<간격>ms_<시각>.log           요약 리포트
#     ws_<연결>c_<간격>ms_<시각>.sessions.csv   세션별 상세(idx,established,rejected,ticks,max_seq,
#                                              first_tick_ms,iv_p50/p99,close_code,error)

WS_LOGDIR=/var/log/wstest WS_LOG=1 python3 scripts/ws_loadclient.py ...   # 디렉터리 지정
```

| env | 기본 | 설명 |
|---|---|---|
| `WS_LOG` | `0` (끔) | `1`/`true`/`on`/`yes` 면 로그 파일 저장 |
| `WS_LOGDIR` | `logs` | 로그 디렉터리 (없으면 생성) |
| `STALL_N` | `0` | 앞쪽 N개 연결을 느린-소비자로 (읽기 중단) |

## 테스트 요약 (2026-09-11, 발생기 2core/1.5GB 단일 박스)

| 시나리오 | 결과 |
|---|---|
| 100~500 연결, 최대 5,000 send/s | seq 누락 0, 세션 p99 106~111ms (서버 여유, CPU 43%) |
| 520 연결 (cap=500) | 초과분 21개 `close 1003` 정상 거절 |
| 하트비트 20연결 × 무송신 200s | `close 1001` = 0 (클라이언트 auto-PONG) |
| Kill: 5,000 연결 램프 | **발생기 포화** (서버 아님) — 누락 0, 지연은 클라 이벤트루프 한계 |
| Kill: 느린소비자 250세션 | executor 락 실패, 정상 세션 무정지 — 서버 생존 |

**결론**: 단일 2코어 발생기로는 서버를 못 죽인다. 병목은 서버가 아니라 발생기.
실제 breakpoint를 보려면 발생기 분산(다수 IP/호스트) 또는 대용량 payload 느린-소비자가 필요.
자세한 내용은 `ws-loadtest-report.html` 참고.

## 주의

- JMeter WebSocket Samplers 는 장시간 시 서버 PING 에 자동 PONG 하는지 확인 필요
  (안 하면 무송신 ~2분 후 `close 1001`). asyncio 클라이언트는 자동 PONG 됨.
- 대량 연결은 발생기의 ephemeral port(기본 ~28k)와 메모리(연결당 ~164KB)가 먼저 병목.

## 분산 부하 — 서버 실한계 찾기 (대규모 연결)

단일 발생기로는 발생기가 먼저 포화된다(위 테스트 결론). 서버 진짜 한계를 보려면 연결을
**여러 프로세스·여러 호스트로 분산**해 서버가 여러 소스에서 연결받게 한다.

| 파일 | 용도 |
|---|---|
| `scripts/run-ws-multi.sh` | 한 박스에서 N프로세스 × C연결 (Python은 프로세스당 1코어) |
| `scripts/run-ws-swarm.sh` | 여러 발생기 호스트에서 동시 실행 (SSH) — 서버가 여러 IP에서 연결받음 |
| `scripts/ws_aggregate.py` | 전 프로세스/호스트 결과 합산 + 서버 한계 신호 판정 |

### A) 한 박스 멀티 프로세스 (다코어 발생기)

```bash
# <총연결> <서버호스트> [포트] [경로] [간격ms] [지속s] [프로세스수(기본=코어수)]
./scripts/run-ws-multi.sh 20000 10.0.0.50 8080 /ws/test 1000 180 8
#   → 8프로세스 × 2,500 = 총 20,000 연결. 끝나면 합산 판정 출력.
```

### B) 여러 발생기 호스트 (스웜) — 서버가 여러 곳에서 연결받는 구조

```bash
# 각 발생기에 python3+websockets, 이 레포가 같은 경로에 있어야 함 (SSH 키 접속)
./scripts/run-ws-swarm.sh "load@10.0.0.11,load@10.0.0.12,load@10.0.0.13" \
    60000 10.0.0.50 8080 /ws/test 1000 180
#   → 3발생기 × 20,000 = 총 60,000 연결이 서버에 3개 IP에서 들어감
```

### 실한계 찾는 법 — 사다리(ladder)로 올린다

연결수를 단계적으로 올리며 **서버가 무너지기 시작하는 지점**을 찾는다:

```bash
for N in 20000 40000 60000 80000; do
  ./scripts/run-ws-multi.sh $N 10.0.0.50 8080 /ws/test 1000 120 8
done
```

각 단계 합산 판정에서 아래가 나오기 시작하는 직전이 **서버 실한계**:
- **거절(close 1003) 증가** → 서버 커넥션 상한 (연결 한계)
- **seq 누락 발생** → 서버가 부하에서 데이터 유실 (처리 한계)
- **틱 간격 p99 ≫ 요청 간격** → 서버 스트리밍 지연 (cadence 한계)

거절·누락 없이 오류만 나면 = **발생기측 포화** → 호스트를 더 늘려(스웜) 재확인. 서버가
아니라 발생기가 한계인지부터 가른다.

### 발생기 준비 (필수)

- **FD·포트**: 대량 연결은 발생기 FD와 임시 포트가 먼저 병목. `ulimit -n 1048576`,
  포트 범위 확장(TUNING.md 1-B). 한 박스는 임시 포트(~28k~64k)가 상한이라
  **6만+ 연결은 반드시 스웜(여러 호스트)** 으로.
- **메모리**: 연결당 ~164KB → 5만 연결 ≈ 8GB.
- **의존성**: `pip install --user "websockets==8.1"` (python 3.6 호환).
