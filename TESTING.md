# JMeter 테스트 실행 가이드 — 3가지 모드

dummy-json 서버(또는 실제 대상)에 대해 목적별로 테스트를 실행하는 방법.
공통 전제: 발생기/서버 커널 튜닝은 `TUNING.md`, 대상 서버 배포는 `jsonserver/README.md` 참고.

| 모드 | 목적 | 도구 | 부하 모델 |
|---|---|---|---|
| 1. 고정 TPS | "1만 TPS를 버티는가" 검증 | `target-tps.jmx` + `run-target-tps.sh` | 목표 TPS로 일정하게 유지 |
| 2. 최대 TPS | "몇 TPS까지 가능한가" 탐색 | `echo-load.jmx` + `run-max-tps.sh` | 무제한 연타, 단계 증가 |
| 3. Agent(분산) | 발생기 1대 한계 초과 부하 | `jmeter-server` + 마스터 `-R` | 에이전트 N대 합산 |

### 어떤 jmx를 쓸까 — 엔드포인트 × 부하 모델 매핑

모든 실행 스크립트는 `PLAN=<jmx>` 환경변수로 플랜을 갈아끼울 수 있다.

| | `/echo` (단순 에코 — 인프라 측정용) | `/custom` (사내 규격 — 결과서용) |
|---|---|---|
| **폐쇄 루프** (vusers/max/multi/calibration) | `echo-load.jmx` (기본값) | `PLAN=custom-load.jmx` |
| **고정 TPS** (run-target-tps) | `target-tps.jmx` (기본값) | `PLAN=custom-target-tps.jmx` |

주의: 고정 TPS 모드에 `custom-load.jmx`를 쓰면 안 된다 — 페이싱 타이머가 없어 목표
TPS 제어가 되지 않는다. 반대로 `custom-target-tps.jmx`를 vUser 모드에 쓰면 think time
대신 타이머가 개입해 의도와 달라진다. **표의 짝 그대로 쓸 것.**

```bash
# 예: 사내 규격으로 1만 TPS 유지 검증
PLAN=custom-target-tps.jmx ./scripts/run-target-tps.sh 10000 <서버IP> 18080 300
# 예: 사내 규격으로 vUser 9,000명
PLAN=custom-load.jmx ./scripts/run-vusers.sh 9000 <서버IP> 18080 1000 300
```

---

## 1. 고정 TPS 모드 — 1만 TPS 설정 및 가이드

**원리**: Constant Throughput Timer가 스레드들을 재워가며 전체 발생량을 목표 TPS에 맞춘다.
스레드 수는 "동시성 공급량", 타이머가 "속도 조절기" 역할. 검증 목적의 표준 모드다.

```bash
# 사용법: run-target-tps.sh <TPS> [HOST] [PORT] [DURATION초]
./scripts/run-target-tps.sh 10000 <서버IP> 18080 300
```

**1만 TPS 권장 설정** (스크립트가 자동 계산하는 값들):

| 항목 | 값 | 근거 |
|---|---|---|
| threads | 500 | `TPS × 평균응답(초) + 여유`. 응답 10ms면 이론상 100이면 되지만 타이머 지터 대비 5배 |
| tpm | 600,000 | CTT 단위는 분당 샘플 수 = TPS × 60 |
| 힙 | `-Xmx6g` | 500 스레드 + 고빈도 샘플 집계 |
| duration | 300s+ | 최소 5분. 순간 스파이크가 아닌 유지 능력 검증이 목적 |

**응답이 느린 대상이면 스레드를 늘려야 한다**: 목표 TPS를 못 채우고 있는데 에러도 없다면
스레드 부족이다 (모든 스레드가 응답 대기 중). `threads ≥ TPS × 응답시간(초) × 2`로 재계산해
`-Jthreads`로 직접 지정:

```bash
JVM_ARGS="-Xms2g -Xmx6g -Xss256k" jmeter -n -t target-tps.jmx \
  -Jhost=<IP> -Jport=18080 -Jtpm=600000 -Jthreads=1000 -Jduration=300 -l out.jtl
```

**판정 기준**:
- 정상상태 `summary +` 가 목표의 ±2% 이내, Err 0% → 합격
- 목표 미달 + 에러 없음 → 스레드 부족 또는 발생기 한계 (캘리브레이션 재확인)
- 목표 미달 + 에러/지연 급증 → **대상 서버 한계** (이게 찾으려던 답)

검증 실측: 목표 200 TPS 지정 시 실측 199.0~200.3/s (오차 0.5%, M4 Pro 루프백).

---

## 2. 최대 TPS 모드 — 설정 및 가이드

**원리**: 타이머 없이 N개 스레드가 쉼 없이 연타(폐쇄 루프). 스레드를 단계적으로 올리며
처리량이 더 안 오르는 지점(plateau)을 찾는다.

```bash
# 사용법: run-max-tps.sh [HOST] [PORT]
./scripts/run-max-tps.sh <서버IP> 18080

# 단계/시간 조정 (환경변수)
MAX_TPS_STAGES="100 300 600 1200" MAX_TPS_DUR=60 ./scripts/run-max-tps.sh <서버IP> 18080
```

기본 단계: 50 → 100 → 200 → 400 → 800 스레드, 각 45초. 끝나면 단계별 TPS 표를 출력한다.

**판정 기준**:
- 스레드 2배 → TPS도 비례 증가: 아직 여유
- 스레드 늘려도 TPS 정체: **직전 단계가 최대 TPS** (동시에 응답시간이 오르기 시작)
- 에러 발생 시작: 이미 한계 초과. 그 전 단계까지가 유효

**주의사항**:
- 시작 전 **발생기 캘리브레이션 필수** (`scripts/run-calibration.sh`) — 발생기 한계 ≥ 예상 최대 TPS×1.3
  이어야 측정이 유효하다. 발생기가 먼저 포화되면 "서버 최대치"가 아니라 "발생기 최대치"를 재게 됨
- 무휴식 연타는 실사용 패턴이 아니다 — 결과는 "이론 상한"이며, 운영 목표는 그 70~80%로 잡는다
- 대상이 실서비스 공유 인프라면 DB/네트워크에 미치는 영향 사전 협의

---

## 3. Agent(분산) 모드 — 설정 및 가이드

**언제 필요한가**: 발생기 1대의 한계(CPU, 포트 16~32k, macOS 스레드 캡 6,144)를 넘는 부하.
예: 5만 TPS, 3만 vUser. 에이전트 N대가 같은 시나리오를 동시에 실행하고 마스터가 결과를 합산한다.

```
마스터(제어/집계)                에이전트(부하 발생)
jmeter -n -R a1,a2,a3  ──RMI──→  jmeter-server × 3대  ──HTTP──→  대상 서버
```

### 3-1. 에이전트 쪽 설정 (RHEL, 부하 발생 담당)

```bash
# 각 에이전트 머신에서 (JMeter 버전은 마스터와 반드시 동일하게)
ulimit -n 65536

# RMI SSL 비활성화 (폐쇄망 내부 통신 — 미설정 시 keystore 없다고 기동 실패)
echo "server.rmi.ssl.disable=true" >> apache-jmeter-5.6.3/bin/user.properties

# 에이전트 기동 (기본 포트 1099)
./jmeter-server -Djava.rmi.server.hostname=<이 에이전트의 IP>
```

### 3-2. 마스터 쪽 설정 (제어/집계 담당)

```bash
echo "server.rmi.ssl.disable=true" >> apache-jmeter-5.6.3/bin/user.properties

# 원격 실행: -R 뒤에 에이전트 IP 목록
jmeter -n -t target-tps.jmx -R 10.0.0.11,10.0.0.12,10.0.0.13 \
  -Ghost=<대상서버IP> -Gport=18080 -Gtpm=200000 -Gthreads=200 -Gduration=300 \
  -l merged.jtl
```

**핵심: `-J`가 아니라 `-G`** — `-J`는 마스터 로컬 프로퍼티, `-G`는 에이전트들에게 전파된다.

### 3-3. 반드시 알아야 할 것들

**부하는 "에이전트당 × N대"로 곱해진다.** 위 예시처럼 `-Gtpm=200000`(에이전트당 약 3,333 TPS)
× 3대 = 합산 1만 TPS. 스레드도 마찬가지: `-Gthreads=200` → 총 600 스레드.
목표를 에이전트 수로 나눠서 지정할 것.

**방화벽 (폐쇄망 신청 시)**:
- 마스터 → 에이전트: TCP 1099 (`server_port`)
- 에이전트 → 마스터: 결과 회신용 임의 포트 — 고정하려면 마스터 `user.properties`에
  `client.rmi.localport=25000` 추가하고 25000~25010 오픈 신청

**기타 규칙**:
- JMeter 버전·Java 버전 마스터/에이전트 동일 (다르면 직렬화 오류)
- 테스트 플랜(.jmx)은 마스터에만 있으면 됨 (실행 시 전송). 단 CSV 데이터 파일은 각 에이전트에 복사
- 커널 튜닝(TUNING.md 1-B)은 **에이전트마다** 적용 — 부하는 에이전트가 만든다
- 결과(.jtl)는 마스터에 합산 수집됨. HTML 리포트: `jmeter -g merged.jtl -o report/`

### 3-4. 간이 대안 — 같은 머신 멀티 인스턴스

에이전트 머신이 따로 없을 때 한 머신에서 프로세스만 나누는 방법 (macOS 스레드 캡 우회에도 사용):

```bash
jmeter -n -t echo-load.jmx -Jthreads=5000 -l a.jtl -j a.log &
jmeter -n -t echo-load.jmx -Jthreads=5000 -l b.jtl -j b.log &
wait
cat a.jtl > merged.jtl && tail -n +2 b.jtl >> merged.jtl   # 결과 병합
```

분산 모드와 달리 마스터 없이 각자 실행 후 수동 병합. 자세한 배경은 TUNING.md 1-A 참고.

---

## 부록: 어느 모드를 쓸까

```
"1만 TPS 요구사항을 충족하는가?"        → 모드 1 (고정 TPS, 5분+ 유지)
"한계가 어디인가? 용량 산정 필요"        → 모드 2 (최대 TPS 탐색)
"목표 부하 > 발생기 1대 한계"           → 모드 3 (분산) 으로 모드 1 또는 2를 실행
테스트 전 발생기 자체 검증               → scripts/run-calibration.sh (원격 서버 대상)
발생기 머신 단독 정밀 검증 (로컬 전용)    → run-calibration.sh (루트 — 더미 서버 자체 기동, 5단계)
```
