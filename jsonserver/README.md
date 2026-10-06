# dummy-json — 부하테스트용 JSON 에코 서버

JSON을 HTTP로 받아 **인입 시각 / 응답 시각**을 찍어 JSON으로 리턴하는 더미 서버.
Go 표준 라이브러리만 사용한 정적 바이너리라 RHEL 8에 복사만 하면 실행된다 (의존성 없음).

## 엔드포인트

| 경로 | 설명 |
|---|---|
| `POST /echo` | JSON 바디를 받아 시각 스탬프와 함께 에코 |
| `POST /echo?delay=50ms` | 처리 지연 시뮬레이션 (Go duration 형식, 최대 30s) |
| `POST /custom` | **커스텀 header/body 규격** — `custom.go`의 수정 구역([구멍 1~3])에서 규격·로직을 직접 정의 |
| `POST /custom?delay=200ms` | 백엔드 처리 지연 시뮬레이션 (in-flight 유지 → 커넥션/버퍼 누적 정찰) |
| `POST /custom?respKB=5120` | 응답 `data._pad` 를 N KB로 팽창 (게이트웨이가 큰 응답 버퍼링 → direct memory 압박). 8~65536. **생략·8 미만·잘못된 값은 8KB** (`custom.go` 의 `defaultRespKB` = 기본이자 최소) |
| `GET /health` | 헬스체크 (`OK`) |

### 부하 정찰 레버 (게이트웨이 breaking point 탐색용)

`?delay=` 와 `?respKB=` 는 조합 가능하며, 게이트웨이가 쿼리스트링을 백엔드로 전달해야 적용된다.
`/custom` 은 **POST + `{"header":{...},"data":{...}}` 구조의 JSON** 만 받는다.
GET 등 다른 메서드는 `405 Method Not Allowed`, 바디 구조가 틀리면 `rspCd 9999` 에 사유를 담아 돌려준다
(오류 전문에는 respKB 패딩이 붙지 않는다):

| 요청 | rspMsg |
|---|---|
| 바디 없음 | `EMPTY_BODY: request body required` |
| JSON 문법 오류 | `INVALID_JSON: ...` |
| `header` 키 없음 / null / 객체 아님 | `MISSING_HEADER: header object required` |
| `data` 키 없음 / null / 객체 아님 | `MISSING_DATA: data object required` |
| `header`·`data` 가 `{}` (빈 객체) | 통과 — 개별 필드 검사는 `custom.go` [구멍 3] 에서 업무 코드로 |

정찰용 호출도 최소 `{"header":{},"data":{}}` 는 보내야 한다:

```bash
curl -s -X POST -d '{"header":{},"data":{}}' 'http://127.0.0.1:18080/custom?respKB=1024' | wc -c   # 약 1MB
curl -s -X POST -d '{"header":{"userId":"TD1"},"data":{"InRec1":{"USER_ID":"1"}}}' \
  'http://127.0.0.1:18080/custom?respKB=5120&delay=200ms'
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:18080/custom'                # GET → 405
curl -s -X POST -d '{}' 'http://127.0.0.1:18080/custom' | grep -o '"rspMsg":"[^"]*"'     # MISSING_HEADER
```

메서드 정리: `GET` 은 `/echo` 와 `/health`(server.sh 기동 확인용) 만 받고, 그 외는 전부 오류다.
관련 부하 플랜(루트):
- `custom-payload.jmx` — `-Jrespkb=<KB> -Jdelayms=<ms>` : **응답 바디** 팽창(서버 생성) + 지연
- `custom-reqbody.jmx` — `-Jreqbytes=<byte>` : **요청 바디** 팽창(JMeter 생성, 랜덤)

응답 팽창은 서버(Go)가, 요청 팽창은 발생기(JMeter)가 만든다 — 데이터를 생성하는 쪽이 다르기 때문.

### /custom 규격 수정 방법

`custom.go` 한 파일만 수정하면 된다 (main.go 불변). 파일 안에 세 구역이 표시돼 있다:

- **[구멍 1]** 요청 규격 — 받을 JSON의 header/body 구조체
- **[구멍 2]** 응답 규격 — 돌려줄 JSON의 구조체 (inTime/outTime/procUs는 자동 주입)
- **[구멍 3]** 처리 로직 — 요청을 보고 응답 채우기 (resCode 분기, `time.Sleep` 지연 등)

수정 후 컴파일: `go build -o dummy-json .` (문법은 GO-GUIDE.md 참고)

요청/응답 예 (사내 전문 규격 — header 22필드 + data.InRec1):

```json
// 요청
{"header":{"mdSect":"H55","svcId":"uwa0000p","uuId":"...","userId":"TD7277", ...},
 "data":{"InRec1":{"USER_PSWD":"1234","USER_ID":"1234","EMAL_ADRS":"","USER_IP":"111","MAC":"111"}}}
// 응답 — 요청 header 전체 에코 + 결과/시간 필드, data는 USER_ID/STATUS 반환
{"header":{ ...요청 header 에코..., "rspCd":"0000","rspMsg":"정상",
            "inTime":"...","outTime":"...","procUs":450},
 "data":{"OutRec1":{"USER_ID":"1234","STATUS":"정상"},
         "_pad":"xxxx..."}}          // 기본·최소 8KB (respKB 생략·0~7 포함). ?respKB=N(8 이상) 으로 조절
```

부하 플랜: 루트의 `custom-load.jmx` (uuId/시각/USER_ID 자동 생성, rspCd 0000 검증 포함).
실행 스크립트에 `PLAN=custom-load.jmx` 를 붙이면 이 규격으로 부하를 건다:

```bash
PLAN=custom-load.jmx ./scripts/run-vusers.sh 5000 <서버IP> 18080 1000 300
```

### /echo 응답 예

```json
{
  "inTime":  "2026-09-02T22:09:23.995487+09:00",   // 요청 수신 시각
  "inEpochMs": 1788354563995,
  "outTime": "2026-09-02T22:09:23.995563+09:00",   // 응답 직전 시각
  "outEpochMs": 1788354563995,
  "procUs": 76,                                     // 서버 내 처리시간 (μs)
  "echo": {"orderId":123,"amount":45000}            // 받은 JSON 그대로
}
```

바디가 JSON이 아니면 `"error":"request body is not valid JSON"`, 바디가 없으면 `echo` 생략.

## 실행 옵션

```
-port 18080        리슨 포트
-accesslog         요청별 in/out 시각을 stdout에 기록 (비동기 버퍼,
                   과부하 시 로그를 버리고 처리량을 지킴 — 버린 수는 stderr에 집계)
-logdir <경로>     stdout 대신 <경로>/access_YYYYMMDD_HHMMSS.log 파일에 기록
                   (기동 시각으로 파일명 생성 — 재기동마다 새 파일. -accesslog 자동 포함)
-logmaxmb 100      액세스 로그 파일이 이 크기(MB)를 넘으면 새 타임스탬프 파일로 로테이션
                   (0 = 로테이션 안 함. -logdir 일 때만 동작)
-logmaxfiles 10    <경로>/<logname>_*.log 를 최대 이 개수만 보관, 초과분은 오래된 순으로 삭제
                   (0 = 무제한. 이전 기동에서 남은 파일도 개수에 포함)
-logname access    액세스 로그 파일명 접두어 → <경로>/<logname>_YYYYMMDD_HHMMSS.log
                   (한 디렉터리에 여러 인스턴스를 띄우면 인스턴스마다 다르게 줘야
                   로테이션·보관 정리가 서로의 파일을 건드리지 않음. server.sh 는 access_<포트> 로 줌)
```

로그 한 줄 형식: `클라IP:포트 in=<epoch ms> out=<epoch ms> proc_us=<처리 μs> bytes=<수신 바이트>`

### 로그 동작 정리

| 기동 방법 | 액세스 로그 | 일반 로그(기동/오류 메시지) |
|---|---|---|
| 옵션 없이 실행 (`-port` 만) | **기록 안 함** | stderr |
| `-accesslog` | stdout | stderr |
| `-logdir logs` | `logs/access_*.log` (로테이션·보관 적용) | stderr |
| `./server.sh start [포트]` | `logs/access_<포트>_*.log` | `logs/server_<포트>_<시각>.log` (pid: `logs/server_<포트>.pid`) |
| `LOGDIR=/data/logs ./server.sh start` | `/data/logs/access_<포트>_*.log` | `/data/logs/server_<포트>_<시각>.log` |
| `ACCESSLOG=0 ./server.sh start` | **기록 안 함** | `logs/server_<포트>_<시각>.log` |
| systemd 유닛 (기본) | **기록 안 함** | `journalctl -u dummy-json` |

여러 인스턴스: `./server.sh start 18080 && ./server.sh start 18081` 처럼 포트만 다르게 주면
같은 `logs/` 안에서 pid·로그가 포트별로 분리된다. `stop`/`status` 도 포트를 붙여서 호출하고,
`status` 에 포트를 생략하면 실행 중인 인스턴스를 전부 보여준다. 다른 빌드를 띄우려면 `BIN=<경로>`.

로테이션 방식: 파일 쓰기는 로거 고루틴 하나만 하므로 잠금 없이 크기 검사 후 새 파일을 연다.
요청 처리 경로는 채널에 한 줄 넣는 것뿐이라 로테이션 순간에도 응답 지연이 생기지 않는다.

- `kill -HUP <pid>` : 현재 파일을 닫고 새 파일을 연다 (외부 logrotate `copytruncate` 없이 연동 가능)
- `kill -TERM <pid>` (server.sh stop) : 버퍼에 남은 로그를 모두 파일에 쓰고 종료 (최대 200ms 분량 유실 방지)
- 로테이션 실패(디스크 풀 등) 시 기존 파일에 계속 쓰고 stderr 에 사유를 남긴다

## 빌드 (macOS에서 크로스 컴파일)

```bash
cd jsonserver
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w" -o dummy-json-linux-amd64 .
```

## RHEL 8 배포

```bash
# 1) 복사
scp dummy-json-linux-amd64 user@rhel8-host:/opt/dummy-json/

# 2) 방화벽 오픈
sudo firewall-cmd --add-port=18080/tcp --permanent && sudo firewall-cmd --reload

# 3-a) 단순 실행 (FD 한도 필수!)
ulimit -n 65536
/opt/dummy-json/dummy-json-linux-amd64 -port 18080

# 3-b) 또는 systemd 등록 (LimitNOFILE 포함됨)
sudo cp deploy/dummy-json.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now dummy-json
```

### 1~2만 TPS급이면 커널 튜닝 권장

```bash
sudo sysctl -w net.core.somaxconn=4096            # accept 백로그
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=8192  # SYN 백로그
```

영구 적용은 `/etc/sysctl.d/90-loadtest.conf`에 기록.

## 실측 성능

Apple M4 Pro(12코어)에서 JMeter 200스레드 keep-alive POST 기준 측정 —
결과는 프로젝트 루트 `results/` 참고. RHEL 8 x86_64 서버에서의 실제 상한은
코어 수와 NIC 대역폭에 따라 다르므로 배포 후 `echo-load.jmx`로 캘리브레이션 권장:

```bash
jmeter -n -t echo-load.jmx -Jport=18080 -Jthreads=200 -Jrampup=5 -Jduration=60 \
  -l result.jtl   # domain은 jmx의 HTTPSampler.domain을 대상 IP로 수정
```
