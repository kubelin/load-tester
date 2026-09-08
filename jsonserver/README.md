# dummy-json — 부하테스트용 JSON 에코 서버

JSON을 HTTP로 받아 **인입 시각 / 응답 시각**을 찍어 JSON으로 리턴하는 더미 서버.
Go 표준 라이브러리만 사용한 정적 바이너리라 RHEL 8에 복사만 하면 실행된다 (의존성 없음).

## 엔드포인트

| 경로 | 설명 |
|---|---|
| `POST /echo` | JSON 바디를 받아 시각 스탬프와 함께 에코 |
| `POST /echo?delay=50ms` | 처리 지연 시뮬레이션 (Go duration 형식, 최대 30s) |
| `POST /custom` | **커스텀 header/body 규격** — `custom.go`의 수정 구역([구멍 1~3])에서 규격·로직을 직접 정의 |
| `GET /health` | 헬스체크 (`OK`) |

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
 "data":{"OutRec1":{"USER_ID":"1234","STATUS":"정상"}}}
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
```

로그 한 줄 형식: `클라IP:포트 in=<epoch ms> out=<epoch ms> proc_us=<처리 μs> bytes=<수신 바이트>`

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
