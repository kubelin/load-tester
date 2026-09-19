# 사내 규격(/custom) 부하테스트 가이드 — custom.jmx + custom-body.json

사내 전문 규격으로 부하를 거는 데 필요한 것은 **파일 두 개**다.

| 파일 | 역할 | 언제 손대나 |
|---|---|---|
| `custom-body.json` | 요청 바디 템플릿 (고정 header + data.inRec1) | **규격이 바뀔 때** — 여기만 고친다 |
| `custom.jmx` | 통합 플랜. 바디를 위 파일에서 읽고, `-J` 프로퍼티로 모드·레버를 결정 | 거의 안 건드림 |
| `scripts/run-custom.sh` | 위 두 파일로 once / tps / vusers / max 모드를 실행하는 래퍼 | — |

서버(`jsonserver/custom.go`)는 header를 **그대로 에코**하고 data는 **요청과 같은 구조에 랜덤 값**을 채우므로,
헤더 필드나 inRec1 필드가 바뀌어도 Go를 고칠 필요가 없다. 응답 코드 규격: HTTP는 항상 200,
`header.rtrnCd`가 `000`으로 시작하면 성공, `999`로 시작하면 실패.

---

## 1. 빠른 시작 (3단계)

```bash
# ① 규격 확인 — 1건만 보내고 실제 전송된 요청/응답을 눈으로 본다
./scripts/run-custom.sh once <서버IP> 18080

# ② 결과서용 고정 TPS — 1만 TPS를 5분 유지
./scripts/run-custom.sh tps 10000 <서버IP> 18080 300

# ③ vUser 시나리오 — 9,000명, think 1초, 5분
./scripts/run-custom.sh vusers 9000 <서버IP> 18080 1000 300

# (탐색) 최대 TPS — 스레드 단계 증가
./scripts/run-custom.sh max <서버IP> 18080
```

`once`는 실제 전송된 요청 바디, 응답 본문, rtrnCd 검증 결과를 출력한다.
바디 템플릿을 고쳤으면 **부하를 걸기 전에 반드시 once로 확인**한다 — 규격이 틀리면 수만 건의
에러 샘플만 쌓인다.

`REPORT=1`을 앞에 붙이면 종료 후 HTML 리포트를 자동 생성한다 (REPORT-GUIDE.md).

---

## 2. 모드가 결정되는 방식

`custom.jmx` 하나에 think-time 타이머와 페이싱 타이머(Constant Throughput Timer)가 함께 들어 있고,
**어떤 프로퍼티를 주느냐**로 모드가 정해진다. 래퍼가 알아서 넣으므로 직접 신경 쓸 일은 없지만
원리는 알아두자.

| 모드 | 래퍼 | 넘기는 핵심 프로퍼티 | 동작 |
|---|---|---|---|
| 고정 TPS | `tps` → `run-target-tps.sh` | `tpm=TPS×60`, `threads` | CTT가 스레드를 재워 목표 TPS 유지. think 없음 |
| vUser | `vusers` → `run-vusers.sh` | `threads`, `thinkms` | `tpm` 미지정(0) → 페이싱 없음. think time만 적용 |
| 최대 TPS | `max` → `run-max-tps.sh` | `threads` 단계 증가, `thinkms=0` | 둘 다 꺼짐 → 무제한 연타 |
| 1건 확인 | `once` | `threads=1`, `loops=1` | 1건 전송 후 종료 |

- `tpm=0`이면 플랜이 페이싱 타이머의 목표를 사실상 무한대로 잡아 지연이 항상 0이 된다 (타이머 무력화).
- `thinkms=0`이면 think 타이머 지연 0 (무력화).
- 옛 플랜 4개(custom-load / custom-target-tps / custom-payload / custom-reqbody)는 이 한 파일로 대체됐다.
  `PLAN=custom.jmx` 로 기존 러너에 직접 꽂아도 된다: `PLAN=custom.jmx ./scripts/run-target-tps.sh 10000 <IP> 18080 300`

---

## 3. 레버 — 게이트웨이 한계점 탐색

환경변수로 준다. 0(기본)이면 플랜은 쿼리스트링을 **아예 붙이지 않고** `_pad`는 빈 문자열이다 (결과서용 요청은 규격 그대로).

| 환경변수 | `-J` | 효과 | 생성 주체 |
|---|---|---|---|
| `REQBYTES=1048576` | `reqbytes` | 요청 최상위 `_pad` 필드에 N바이트 랜덤 문자열 (header/data는 그대로) | JMeter |
| `RESPKB=5120` | `respkb` | `?respKB=N` → 응답을 N KB로 팽창 | 서버(custom.go) |
| `DELAYMS=200` | `delayms` | `?delay=Nms` → 서버가 N ms sleep (in-flight 누적) | 서버(custom.go) |
| `FAIL=0.01` | `fail` | `?fail=p` → 요청의 p 비율을 `rtrnCd 999` 응답으로 (HTTP는 200). 어설션·에러율 집계 동작 확인용 | 서버(custom.go) |

```bash
# 응답 5MB + 200ms 지연을 vUser 2,000명이 think 없이 5분 — 게이트웨이 direct memory / 커넥션 누적 관찰
RESPKB=5120 DELAYMS=200 ./scripts/run-custom.sh vusers 2000 <서버IP> 18080 0 300

# 1MB 요청 바디를 500 TPS로
REQBYTES=1048576 ./scripts/run-custom.sh tps 500 <서버IP> 18080 300

# 레버가 실제로 붙었는지 1건으로 확인 (URL에 ?respKB=..&delay=..ms, _pad 채워짐)
RESPKB=64 DELAYMS=50 REQBYTES=100 ./scripts/run-custom.sh once <서버IP> 18080

# 실패 주입 1%로 5분 — 리포트의 에러율이 약 1%로 집계되고 Errors 표에 Assertion failed로 찍히는지 확인
FAIL=0.01 ./scripts/run-custom.sh tps 1000 <서버IP> 18080 300
```

쿼리스트링 레버는 **게이트웨이가 쿼리를 백엔드로 그대로 전달**해야 동작한다. 응답에 `procUs`가
지연만큼 커졌는지(`once`로 확인)로 전달 여부를 판단할 수 있다.

---

## 4. 규격 수정하기 — custom-body.json

템플릿은 JSON이지만 값 자리에 JMeter 함수를 쓸 수 있다. 시작 시 파일을 **한 번만** 읽어 변수에
담고, 매 요청마다 함수 부분만 평가한다 (파일 I/O는 매 요청 없음).

현재 템플릿은 PBS 규격(`mdSect H57`, `svcId OAPBZCM001R01`)이다. header는 고정값(대부분 null),
data는 `inRec1` 5개 필드, 그리고 요청 팽창 레버용 최상위 `_pad`(기본 빈 문자열).

수정 규칙:
1. **고정값은 그냥 바꾸면 된다** (`"svcId": "OAPBZCM001R01"` → 다른 서비스 ID). null·숫자(`"langTyp": 1`)도 그대로 둔다.
2. **header 필드 추가/삭제, inRec1 필드 변경은 서버를 안 고쳐도 된다.** 서버는 header를 map으로 받아 그대로
   에코하고, data는 요청 구조를 따라 랜덤을 채운다 (`inRec1` → `outRec1`, 배열 레코드도 같은 길이로).
3. 값을 요청마다 달리하려면 JMeter 함수를 쓴다. 자주 쓰는 것:
   `"${__UUID}"`(uuId), `"TD${__threadNum}"`(스레드별 유저), `${__Random(1,1000)}`, `"${__RandomString(8,ABCDEFG0123456789)}"`,
   `"${__time(yyyyMMdd)}"`. 함수 안에 콤마가 필요하면 `\,`로 이스케이프. 숫자 필드에 넣을 땐 따옴표 없이.
4. 계좌번호·고객ID처럼 **실제 데이터 목록**이 필요하면 CSV Data Set을 붙이는 것이 정석이다
   (플랜에 `CSVDataSet` 추가 → 템플릿에서 `${ACNT_NO}` 참조). 필요하면 별도로 구성한다.
5. 규격이 엄격해 **모르는 필드를 거부하는 대상**이라면 `_pad` 줄을 지운다 (그러면 `REQBYTES` 레버는 비활성).
6. 고친 뒤 **`once`로 확인** → `rtrnCd 000`, 응답 header에 값이 그대로 에코되고 `outRec1`이 같은 필드로 나오는지.

**서버 로직이 필요할 때만** `custom.go`를 고친다 — 예: 특정 입력에 실패 코드를 내거나 응답 data를 고정값으로.
[구멍 3] `processCustom`에 조건을 넣고 재빌드한다(GO-GUIDE.md). 결과 코드 키·접두어는 [구멍 1] 상수.

다른 규격 파일을 쓰려면 `BODY=path/to/other.json`. 서비스별 템플릿을 여러 개 두고 골라 쓰면 된다:
```bash
BODY=bodies/OAPBZCM002R01.json ./scripts/run-custom.sh tps 3000 <서버IP> 18080 300
```

---

## 5. 출력 — HTML 리포트와 결과서 숫자

| 출력 | 만드는 법 | 위치 |
|---|---|---|
| HTML 리포트 (그래프 증적) | 실행 앞에 `REPORT=1` | `results/report_<태그>/index.html` (폴더째 복사해 브라우저로) |
| 결과서 숫자 (TPS·에러율·p50/p90/p95/p99/max) | `./scripts/summarize-jtl.sh <jtl> <램프업초>` | 터미널 출력 |
| 1건 요청/응답 전문 | `once` 모드 | `results/once_<시각>.xml` |

```bash
REPORT=1 ./scripts/run-custom.sh tps 10000 <서버IP> 18080 300          # 리포트 자동 생성
./scripts/summarize-jtl.sh results/result_target10000_<시각>.jtl 30      # 앞 30초(램프업) 제외
JVM_ARGS=-Xmx6g jmeter -g results/result_target10000_<시각>.jtl -o results/report_target10000/   # 나중에 따로
```

`max` 모드는 단계별 부하 조건이 다르므로 단계마다 리포트를 하나씩 만든다 (병합하지 않음).

**리포트 설정 (발생기 VM에서 1회).** JMeter 대시보드 기본값은 그래프가 1분 버킷이고 APDEX 기준이
500ms/1500ms라 금융 시스템 기준으로 거칠다. 루트의 `jmeter-user.properties`를 이어붙이면 5초 버킷,
APDEX 50ms/200ms로 바뀐다:

```bash
cat jmeter-user.properties >> ~/apache-jmeter-5.6.3/bin/user.properties
```

결과서에 캡처할 화면은 Statistics 표(p99 포함), Transactions Per Second(목표선 유지 여부),
Response Times Over Time(우상향 여부) 세 가지. 상세는 REPORT-GUIDE.md 4장과 `jmeter-report-guide.html`.

---

## 6. 판정 기준 (결과서)

| 항목 | 기준 |
|---|---|
| 처리량 | `summary +` 정상상태 구간이 목표 TPS ±5% (고정 TPS 모드) |
| 에러 | `Err: 0 (0.00%)`. HTTP가 항상 200이므로 **어설션이 유일한 오류 검출** — `header.rtrnCd`가 `000`으로 시작하지 않으면 에러. 결과서에 "HTTP 200 + rtrnCd 999 = 업무 오류로 집계"라고 판정 기준을 명시 |
| 응답시간 | p99가 SLA 이내, 시간이 지나도 우상향하지 않음 (누적 징후) |
| 서버 | access log `proc_us`가 안정. 발생기 RT − proc_us = 네트워크/게이트웨이 구간 |

목표 TPS를 못 채우는데 에러가 없으면 스레드 부족이다 → `EXTRA_JOPTS="-Jthreads=1000"`
(계산은 TESTING.md 1장, FORMULAS.md).

---

## 7. 알아둘 점

**발생기 오버헤드.** 바디를 매 요청 템플릿에서 평가(`__eval`)하고 페이싱 타이머가 항상 트리에 있어,
옛 인라인 플랜 대비 **단일 스레드 무제한 처리량이 약 30% 낮다** (검증 환경: 3,900/s → 2,700/s,
`__eval` 약 20%, 타이머 약 15%). 이는 발생기 CPU 비용이지 대상 서버 측정값이 아니다.
- 고정 TPS 1만 모드에서는 요청당 수십 µs = 코어 0.5개 수준이라 무시해도 된다.
- `max` 모드로 **발생기 한 대의 한계**를 재는 경우에는 `echo-load.jmx`(/echo)로 재는 것이 정확하다
  (TESTING.md 2장). custom 경로의 최대 TPS는 규격 검증용 참고치로 본다.
- 정말 custom 경로에서 발생기 한계까지 짜내야 하면 에이전트를 늘리는 것(run-agents.sh)이 정답이다.

**분산(agent) 실행.** `PLAN=custom.jmx ./scripts/run-agents.sh ...` 로 쓴다. 바디 파일은 **에이전트 머신마다**
있어야 한다 — 마스터가 보내는 것은 jmx뿐이고, `custom-body.json`은 각 에이전트가 자기 실행 디렉터리
(start-agent.sh가 cd 하는 레포 루트)에서 읽는다. 레포를 그대로 배포했다면 이미 있다.
레버는 `EXTRA_GOPTS="-Grespkb=5120 -Gdelayms=200"` 로 넘긴다.

**바디 파일 경로.** `custom.jmx`를 직접 `jmeter -n -t custom.jmx`로 돌리면 `custom-body.json`은 **jmeter를
실행한 디렉터리** 기준이다 (레포 루트에서 실행하거나 `-Jbody=/절대경로`). 래퍼는 절대경로로 바꿔 넘기므로
어디서 실행해도 된다.

**포트 기본값.** 플랜/러너의 기본 포트는 18082, 배포 문서의 서버 포트는 18080이다. 항상 인자로 명시할 것.

---

## 8. 트러블슈팅

| 증상 | 원인 → 조치 |
|---|---|
| once에서 "샘플이 기록되지 않았습니다" | 바디 파일 경로 오류 또는 함수 문법 오류. `results/jmeter_once_*.log` 확인 |
| 응답 `rtrnCd 999`, `rsltMsg INVALID_JSON` | 템플릿이 JSON으로 깨짐 (콤마·따옴표). once 출력의 요청 본문을 JSON 검사기에 넣어본다 |
| Err 100%, 응답 200 | 어설션 실패 — 응답에 `"rtrnCd":"000…"`이 없다. 대상의 성공 코드 규격이 다르면 `custom.jmx`의 `Assert rtrnCd starts with 000` 정규식 수정 |
| Err가 FAIL 비율만큼 나옴 | 정상 — 실패 주입 레버가 켜져 있다. `FAIL` 환경변수를 지운다 |
| 레버를 줬는데 procUs가 안 늘어남 | 게이트웨이가 쿼리스트링을 버림. 대상 서버에 직접 once로 비교 |
| 요청 팽창 시 413/400 | 서버 `customMaxBody`(64MB) 또는 게이트웨이 바디 한도 초과 |
| 목표 TPS 미달, Err 0 | 스레드 부족 → `EXTRA_JOPTS="-Jthreads=N"` (N ≥ TPS × RT초 × 2) |
