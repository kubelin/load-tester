# 회사 VM 배포 가이드 — 순서대로 따라하기

폐쇄망 RHEL 8 기준. 서버 VM(테스트 대상)과 발생기 VM(JMeter)을 구분해서 표기한다.
한 대로 겸용할 경우 두 역할의 절차를 같은 VM에 모두 적용하면 된다 (단, 측정치는 보수적으로 해석).

```
[0] 반입 준비 → [1] VM 점검·커널 요청 → [2] 서버 배포 → [3] 발생기 설치
→ [4] 캘리브레이션 → [5] 본 테스트 → [6] 리포트·원복
```

---

## 0. 반입 준비 (인터넷 되는 곳에서)

**이 레포를 통째로 받는다** — 바이너리·소스·Go 툴체인·문서가 다 들어있다:

```bash
git clone git@github.com:kubelin/load-tester.git   # 또는 웹에서 zip 다운로드
```

**레포에 없어서 따로 받아야 하는 것** (발생기 VM용):

| 파일 | 출처 | 용도 |
|---|---|---|
| JDK 17 (tar.gz) | adoptium.net → OpenJDK17 linux x64 | JMeter 실행 |
| apache-jmeter-5.6.3.zip | jmeter.apache.org/download | 부하 발생기 |

반입 목록 최종: **레포 폴더 전체 + JDK tar.gz + JMeter zip** (3개 묶음).

---

## 1. VM 점검 및 커널 변경 요청 (서버·발생기 공통)

각 VM에서 현재값 점검 (root 불필요):

```bash
cd load-tester
./scripts/check-kernel-loadgen.sh
```

`[변경필요]` 항목이 있으면 → **TUNING.md 6-2장의 요청서 양식**으로 인프라팀에 신청:
- sysctl: `/etc/sysctl.d/90-loadtest.conf` 생성 요청
- ulimit: `/etc/security/limits.d/90-loadtest.conf` 생성 요청
- 방화벽: 서버 VM의 테스트 포트(18080/tcp) 오픈 요청

적용 후 재실행해서 전 항목 `[OK]` 확인. **ulimit 항목은 재로그인 후 반영**되는 점 주의.

---

## 2. 서버 VM — dummy-json 배포

**권장: 레포 폴더에서 그대로 실행한다** — 별도 복사본을 만들면 pull 해도 그 사본은
안 바뀌어서 구버전 바이너리 사고가 난다 (`flag provided but not defined` 류 에러의 원인).

```bash
# 2-1. 기동 — 방법 A: server.sh (권장. ulimit·백그라운드·logs/ 자동)
cd load-tester/jsonserver
./server.sh start 18080        # logs/는 "실행한 현재 폴더"에 생성
./server.sh status / stop      # 관리

# 2-1. 기동 — 방법 B: systemd (상시 유지·재부팅 생존 필요시)
#   유닛의 ExecStart 경로를 레포 위치로 맞춘 뒤:
sudo cp jsonserver/deploy/dummy-json.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now dummy-json

# 2-2. 동작 확인 (서버 VM 자신에서)
curl -s http://127.0.0.1:18080/health          # → OK
curl -s -X POST http://127.0.0.1:18080/custom -d '{"data":{"InRec1":{"USER_ID":"77"}}}'
#   → rspCd/OutRec1 포함 응답이면 최신 바이너리 (없으면 구버전 — git pull 확인)
```

JSON 규격 수정이 필요해지면: `jsonserver/custom.go`의 [구멍 1~3] 수정 → 재빌드
(GO-GUIDE.md 0장, 폐쇄망 내 빌드는 offline/README.md) → `./server.sh stop && start`.
부득이 /opt 등에 사본을 두는 정책이면 **pull 할 때마다 바이너리 재복사**를 세트로.

---

## 3. 발생기 VM — JDK + JMeter 설치 (압축 해제가 곧 설치)

```bash
# 3-1. JDK
tar -C ~ -xzf OpenJDK17*.tar.gz
export JAVA_HOME=~/jdk-17*          # 실제 폴더명으로
export PATH=$JAVA_HOME/bin:$PATH
java -version                        # 17.x 확인

# 3-2. JMeter
unzip apache-jmeter-5.6.3.zip -d ~
export PATH=~/apache-jmeter-5.6.3/bin:$PATH
jmeter --version                     # 5.6.3 확인

# 3-3. PATH 영구화
echo 'export PATH=$HOME/jdk-17*/bin:$HOME/apache-jmeter-5.6.3/bin:$PATH' >> ~/.bashrc

# 3-4. 발생기 → 서버 통신 확인
curl -s http://<서버VM IP>:18080/health   # → OK (안 되면 방화벽부터 확인)
```

---

## 4. 캘리브레이션 — 발생기·환경 한계 실측 (본 테스트 전 필수)

발생기 VM의 load-tester 폴더에서 (목표 TPS를 넘기면 합격/불합격까지 자동 판정):

```bash
./scripts/run-calibration.sh <서버VM IP> 18080 10000
```

**판정**: 정상상태 발생 능력이 **본 테스트 목표의 1.3배 이상**이면 통과.
(예: 목표 1만 TPS → 캘리브레이션에서 1.3만+ 나와야 함 — 스크립트가 판정 출력)
미달이면 측정이 오염되므로 원인(발생기 CPU, 네트워크, 커널 설정)을 먼저 해소한다.
테스트 중 서버 VM에서 `top`으로 CPU와 `%st`(steal)도 함께 확인.

---

## 5. 본 테스트 (TESTING.md의 3개 모드)

```bash
# 모드 1 — 1만 TPS 유지 검증 (5분)
./scripts/run-target-tps.sh 10000 <서버VM IP> 18080 300

# 모드 2 — 최대 TPS 탐색
./scripts/run-max-tps.sh <서버VM IP> 18080

# 유저 시나리오 — vUser 5,000명 (1초 think time, REPORT=1 붙이면 HTML 리포트까지)
./scripts/run-vusers.sh 5000 <서버VM IP> 18080 1000 300
```

판정 기준·스레드 산정은 TESTING.md와 FORMULAS.md 참고.
발생기 1대 한계를 넘는 목표면 TESTING.md 3장(agent 분산 모드)으로.

---

## 6. 리포트 생성 및 원복

```bash
# HTML 리포트 (그래프 포함, 결과 공유용)
jmeter -g result.jtl -o report/     # report/index.html 열기

# 테스트 종료 후 원복
sudo systemctl disable --now dummy-json          # 서버 중지
# 커널 설정 원복이 필요하면: /etc/sysctl.d/90-loadtest.conf 삭제 후 재부팅 요청
```

---

## 자주 걸리는 것 요약

| 증상 | 원인 | 해결 |
|---|---|---|
| `Too many open files` | ulimit 미적용 (재로그인 안 함) | 1장 재확인 |
| `Connection refused` | 방화벽 / 서버 미기동 | 2-3, 3-4 확인 |
| 목표 TPS 미달 + 에러 0% | 스레드 부족 | FORMULAS.md ② |
| 간헐 timeout/reset | accept 큐, conntrack | TUNING.md 2장 |
| 캘리브레이션 수치가 낮음 | VM CPU steal, 가상 NIC | `top`의 `%st` 확인, 인프라팀 문의 |
