# 부하테스트 OS 커널 튜닝 가이드

부하 발생기(JMeter가 도는 장비)와 수신 서버(테스트 대상)는 병목 지점이 다르므로 나눠서 정리한다.
모든 `sysctl -w`는 **재부팅 시 초기화**된다. 영구화 방법은 맨 아래 참고.

## 증상 → 원인 빠른 대조표

| 증상 | 의심 지점 | 설정 |
|---|---|---|
| `Too many open files` | 양쪽 FD 한도 | `ulimit -n` / `LimitNOFILE` |
| `Cannot assign requested address` (발생기) | 임시 포트 고갈 | 포트 범위, TIME_WAIT |
| `Connection refused` / connect timeout (간헐) | 서버 accept 큐 넘침 | `somaxconn`, `tcp_max_syn_backlog` |
| `Connection reset` / no response (간헐) | 서버 커넥션 정책·워커 고갈 | WAS 설정 (OS 아님) + conntrack |
| 발생기 응답시간이 이유 없이 튐 | 발생기 CPU 포화 | 튜닝 아닌 캘리브레이션 문제 |

---

## 1. 부하 발생기 (JMeter 실행 장비)

### 1-A. macOS (개발 맥)

**필수 — 파일 디스크립터.** 터미널 기본값 2,560으로는 동시 커넥션 ~2,300에서 죽는다.
JMeter를 실행할 **바로 그 셸에서**:

```bash
ulimit -n 65536
```

커널 상한은 보통 충분하다 (`kern.maxfilesperproc` ≈ 92k). 매번 치기 싫으면 `~/.zshrc`에 추가.

**조건부 — Keep-Alive를 끄고 테스트할 때만.** 매 요청 새 연결이면 임시 포트(기본 49152–65535,
약 16k개)가 TIME_WAIT(기본 30초)에 묶여 초당 신규 연결 ~550개가 상한이 된다.

```bash
sudo sysctl -w net.inet.ip.portrange.first=32768   # 포트 2배로
sudo sysctl -w net.inet.tcp.msl=5000               # TIME_WAIT 30s → 10s
# 테스트 후 원복: sudo sysctl -w net.inet.tcp.msl=15000
```

**장시간 테스트 — 절전 방지:**

```bash
caffeinate -dims jmeter -n -t plan.jmx ...
```

**macOS 한정 — 프로세스당 스레드 하드 캡 (6,144개, 변경 불가)**

macOS는 `kern.num_taskthreads`(=6,144)로 프로세스 하나의 스레드 수를 제한한다.
JMeter는 vUser 1명 = 스레드 1개라서 **단일 인스턴스로 최대 ~6,100 vUser가 한계**
(JVM 내부 스레드 ~35개 제외). 그 이상은 요청해도 조용히 6,100 근처에서 멈춘다.

해법: **JMeter 프로세스를 나눠서 띄운다.** 캡은 프로세스당이므로 2개면 1만 vUser 가능.

```bash
# 같은 jmx, 결과/로그 파일만 분리 (같은 파일에 쓰면 깨짐)
JVM_ARGS="-Xms2g -Xmx4g -Xss256k" jmeter -n -t plan.jmx -Jthreads=5000 \
  -l result_a.jtl -j jmeter_a.log &
JVM_ARGS="-Xms2g -Xmx4g -Xss256k" jmeter -n -t plan.jmx -Jthreads=5000 \
  -l result_b.jtl -j jmeter_b.log &
wait

# 결과 병합 → HTML 리포트
cat result_a.jtl > merged.jtl
tail -n +2 result_b.jtl >> merged.jtl
jmeter -g merged.jtl -o report/
```

주의: 스레드 캡은 프로세스당이지만 **임시 포트와 CPU는 머신 공유**다.
합산 1만 커넥션이면 포트 범위 확장(위 1-A)이 필수가 된다.
리눅스 발생기는 이 캡이 없으므로(수만 개, `ulimit -u`로 조절) 분할 불필요.

> 실측 (M4 Pro 12C/24G, 루프백): 5,000×2 = 1만 vUser(think 1s) →
> 정상상태 합산 ~8,650 RPS, 에러 0%. 포트 확장 전에는 포트 고갈로 에러 6~8% 발생,
> 확장 후 해소. 잔여 0.03%는 macOS accept 큐(somaxconn=128) 순간 넘침.

### 1-B. Linux (RHEL 등에서 JMeter를 돌릴 경우)

```bash
# 셸 한도 (또는 /etc/security/limits.conf 에 nofile 65536)
ulimit -n 65536

# 임시 포트 확장 (기본 32768–60999 ≈ 28k개 → 64k개)
sudo sysctl -w net.ipv4.ip_local_port_range="1024 65000"

# TIME_WAIT 소켓 재사용 (발생기에서 안전, 서버에선 불필요)
sudo sysctl -w net.ipv4.tcp_tw_reuse=1

# FIN_WAIT2 대기 단축
sudo sysctl -w net.ipv4.tcp_fin_timeout=15
```

`tcp_tw_recycle`은 RHEL 8 커널에서 제거됐다(NAT 환경 장애 유발). 쓰지 말 것.

### 1-C. JMeter 자체 (OS는 아니지만 세트로)

```bash
JVM_ARGS="-Xms2g -Xmx8g -Xss256k" jmeter -n -t plan.jmx -l out.jtl
```

- CLI 모드(`-n`) 필수, 무거운 리스너(View Results Tree) 제거
- `-Xss256k`: 스레드 스택 축소 → 5,000 스레드 시 스택 메모리 5GB → 1.25GB
- 실측 기준(M4 Pro 12C/24G): think time 있는 5,000 vUser 여유, 무휴식 시 3,000 이하 권장

---

## 2. 수신 서버 (RHEL 8, 테스트 대상)

### 필수 — 파일 디스크립터

동시 커넥션 1개 = FD 1개. systemd 서비스라면 유닛에:

```ini
[Service]
LimitNOFILE=65536
```

수동 실행이면 `ulimit -n 65536` 후 기동. 시스템 전체 상한도 확인:

```bash
sysctl fs.file-max        # 보통 수십만 이상, 부족하면 sysctl -w fs.file-max=1000000
```

### 필수 — accept 큐 (순간 폭주 대비)

램프업 순간에 SYN이 몰리면 큐가 넘쳐 connection refused/timeout이 난다.

```bash
sudo sysctl -w net.core.somaxconn=4096            # accept 완료 큐 (기본 128)
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=8192  # SYN 수신 큐
```

주의: 애플리케이션의 listen backlog도 함께 커야 한다. Go `net/http`는 somaxconn을
자동 사용하므로 OS만 올리면 됨. Tomcat은 `acceptCount`, nginx는 `listen ... backlog=4096` 별도 설정.

### 권장 — 2만 TPS급일 때

```bash
# NIC 수신 큐 (소프트인터럽트 처리 전 대기열)
sudo sysctl -w net.core.netdev_max_backlog=8192

# 소켓 버퍼 상한 (대역폭 큰 응답일 때)
sudo sysctl -w net.core.rmem_max=16777216
sudo sysctl -w net.core.wmem_max=16777216
sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"
```

### 함정 — conntrack (firewalld/iptables 켜져 있으면 필수 확인)

RHEL 8 기본 firewalld는 모든 커넥션을 conntrack 테이블에 기록한다.
테이블이 차면 **커널이 조용히 패킷을 버려서** 원인 찾기 어려운 간헐 실패가 난다.

```bash
sysctl net.netfilter.nf_conntrack_max                 # 현재 상한 확인
sudo sysctl -w net.netfilter.nf_conntrack_max=262144  # 필요시 증설
# 테스트 중 사용량 모니터: watch cat /proc/sys/net/netfilter/nf_conntrack_count
```

내부 성능 테스트라면 방화벽을 잠시 내리는 것도 방법(`systemctl stop firewalld`) — 보안 정책 확인 후.

### 선택 — TIME_WAIT (서버가 먼저 끊는 구조일 때)

Keep-Alive 미사용 + 서버 측이 연결을 닫는 패턴이면 서버에 TIME_WAIT이 쌓인다.

```bash
sudo sysctl -w net.ipv4.tcp_fin_timeout=15
```

서버는 임시 포트를 안 쓰므로(리슨 포트 하나로 4-tuple 구분) 포트 고갈은 발생기만의 문제다.

---

## 3. 적용 확인 · 영구화 · 원복

```bash
# 현재값 확인
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog
ulimit -n

# 영구화 (RHEL): /etc/sysctl.d/90-loadtest.conf 에 기록 후
sudo sysctl --system

# 원복: 위 파일 삭제 후 재부팅, 또는 개별 sysctl -w 로 기본값 되돌리기
```

테스트 전용 장비가 아니라면 **영구화보다 테스트 시에만 적용 후 원복**을 권장.

## 4. 튜닝으로 해결 안 되는 것

- **네트워크 대역폭**: NIC/스위치가 감당하는지 먼저 계산 (5장 공식)
- **발생기 CPU 포화**: 커널이 아니라 부하 설계 문제 → 캘리브레이션으로 상한 실측 후 70~80%로 운용
- **WAS 애플리케이션 설정**: 워커 스레드풀, keep-alive 정책, DB 커넥션 풀은 OS가 아닌 WAS/앱에서
  (Tomcat `maxThreads`·`maxConnections`, JEUS 웹엔진 thread pool, WebtoB `MaxUser` 등)

---

## 5. 대역폭 → 최대 TPS 계산 공식

테스트 설계 전에 "이 조합이 네트워크상 가능한가"를 먼저 걸러낸다.

```
① 대역폭을 바이트로:   10 Gbps ÷ 8 = 1,250 MB/s
② 트랜잭션 1건 크기:   요청 + 응답 + 프로토콜 오버헤드(HTTP 헤더 ~300B, TCP/IP ~66B×왕복 패킷수)
③ 이론 최대 TPS:       ① ÷ ②
```

**암산 공식** (자주 쓰는 형태):

```
필요 대역폭(Gbps) ≈ 트랜잭션 크기(KB) × TPS(만 단위) × 0.08

예: 10KB 트랜잭션 × 2만 TPS → 10 × 2 × 0.08 = 1.6 Gbps
```

**10G NIC 기준 조견표** (요청+응답 합산 크기):

| 트랜잭션 크기 | 2만 TPS | 5만 TPS | 이론 최대 TPS |
|---|---|---|---|
| 1KB (소형 JSON) | 0.16 Gbps (2%) | 0.4 Gbps (4%) | ~125만 |
| 10KB | 1.6 Gbps (16%) | 4 Gbps (40%) | ~12만 |
| 50KB | 8 Gbps (80%) | 20 Gbps — **불가** | ~2.5만 |

주의:
- 이론치의 **60~80%를 실용 한계**로 본다 (TCP 혼잡제어, ACK, 재전송 오버헤드)
- 작은 패킷 다량이면 대역폭보다 **pps 한계**가 먼저 온다 (특히 VM 가상 NIC)
- 대역폭 계산은 "불가능 조합 필터"일 뿐, 가능 범위 내 실측은 캘리브레이션으로

---

## 6. 부하 발생기 커널 값 점검 → 변경 요청 절차

회사 VM처럼 직접 root 권한이 없는 환경에서 인프라팀에 변경을 요청하는 흐름.

### 6-1. 조회 및 검토

발생기 VM에서 (root 불필요):

```bash
./scripts/check-kernel-loadgen.sh
```

현재값과 권장값을 대조해 `[OK] / [변경필요]`로 출력한다. 출력을 그대로 요청서에 첨부.
스크립트를 못 옮기는 환경이면 수동 조회:

```bash
ulimit -Sn; ulimit -Hn; ulimit -Su
sysctl fs.file-max fs.nr_open kernel.threads-max kernel.pid_max vm.max_map_count
systemctl show user-$(id -u).slice --property=TasksMax   # cgroup 스레드 한도 (6-2 C)
sysctl net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout
sysctl net.core.rmem_max net.core.wmem_max net.netfilter.nf_conntrack_max
```

### 6-2. 변경 요청서 (인프라팀 전달용 양식)

> **목적**: 부하테스트 발생기(JMeter) 운용 — 동시 커넥션 1만+, 신규 커넥션 초당 수천 건 발생
> **대상 서버**: (호스트명/IP)
> **원복 조건**: 부하테스트 기간 종료 후 원복 가능 (영구 적용도 무방 — 서비스 영향 없는 상향 조정임)

**A. sysctl — `/etc/sysctl.d/90-loadtest.conf` 생성 후 `sysctl --system`**

```ini
# 파일 디스크립터
fs.file-max = 1000000
fs.nr_open = 1048576

# 스레드/프로세스 (JMeter 1만+ 스레드)
kernel.threads-max = 100000
kernel.pid_max = 100000
vm.max_map_count = 262144

# 임시 포트 / TIME_WAIT (신규 커넥션 발생 능력)
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# 소켓 버퍼
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# 방화벽(conntrack) 사용 시에만
net.netfilter.nf_conntrack_max = 262144
```

**B. 사용자 한도 — `/etc/security/limits.d/90-loadtest.conf` 생성 (재로그인 후 적용)**

```
<jmeter실행계정>  soft  nofile  65536
<jmeter실행계정>  hard  nofile  65536
<jmeter실행계정>  soft  nproc   65536
<jmeter실행계정>  hard  nproc   65536
```

**C. systemd TasksMax — A·B와 별개의 세 번째 계층 (SSH 세션의 cgroup 스레드 한도)**

sysctl과 limits.d를 다 올려도 systemd가 로그인 세션(cgroup) 단위로 스레드 수를
따로 제한할 수 있다. 기본값이 1만 근처인 배포판이 있어 **"8천은 되는데 1만은 안 되는"
증상의 단골 원인**. 확인:

```bash
systemctl show user-$(id -u).slice --property=TasksMax   # infinity 또는 65536+ 이어야 함
```

숫자가 작게 나오면 요청 항목:

```
/etc/systemd/logind.conf 에  UserTasksMax=65536  설정 후 systemd-logind 재시작
(또는 systemctl set-property user-<uid>.slice TasksMax=infinity)
```

### 6-3. 적용 확인

변경 후 발생기 VM에서 다시:

```bash
./scripts/check-kernel-loadgen.sh   # 전 항목 [OK] 확인
```

`ulimit` 항목은 **재로그인(새 세션)** 후에 반영되는 점 주의.
`tcp_tw_recycle`은 요청하지 말 것 — RHEL 8 커널에서 제거됐고 NAT 장애를 유발하던 옵션이다.

---

## 7. 네트워크 점검 (NIC·대역폭·경로)

부하는 "경로 전체"를 지나간다. 발생기 NIC이 빵빵해도 **경로에서 가장 좁은 곳이 실제 상한**이고,
거기서 막히면 측정값이 "서버 성능"이 아니라 "네트워크 한계"를 재게 된다. 5장(대역폭 계산)이
"얼마가 필요한가"라면, 이 장은 "경로가 그걸 감당하나"를 확인한다.

### 7-1. 본딩 NIC — 여러 장 묶어도 자동으로 배가되지 않는다

**대부분의 본딩 모드에서 단일 TCP 커넥션은 물리 NIC 한 장 속도를 못 넘는다.** 대역폭 합산은
여러 커넥션이 여러 NIC에 분산될 때만 일어난다.

| 모드 | 대역폭 효과 |
|---|---|
| mode 1 (active-backup) | 증가 없음 — 1장만 활성 (장애대비) |
| mode 4 (802.3ad/LACP) | 합산 가능 — 플로우별 해시로 NIC 배정, 스위치 LACP 설정 필수 |
| mode 2 (balance-xor) | 해시 분산 (LACP 없이) |
| mode 5/6 (tlb/alb) | 적응형 분산, 스위치 설정 불필요 |
| mode 0 (round-robin) | 단일 커넥션도 여러 NIC 사용하나 패킷 재정렬로 TCP 저하 |

**부하테스트의 함정 — 단일 대상이면 1장에 몰린다:** LACP 기본 해시(`layer2` = MAC 기준)는
도착 MAC이 항상 같아서(스위치/게이트웨이 하나) 전 트래픽이 NIC 한 장에 갇힌다. 4×10G 묶어도
실제 10G만 나오는 것. 분산하려면 해시를 `layer3+4`(IP+포트)로 바꾸고 커넥션이 다양해야 한다.

```bash
cat /proc/net/bonding/bond0            # 모드·슬레이브·해시정책·LACP 한눈에
#   Bonding Mode: ...                   ← 모드
#   Transmit Hash Policy: layer2 (0)    ← ★ layer3+4 아니면 단일대상서 1장에 몰림
#   Slave Interface + Speed             ← 각 NIC 속도
cat /sys/class/net/bond0/bonding/xmit_hash_policy
for i in eth0 eth1; do ethtool $i | grep Speed; done
```

### 7-2. 경로가 게이트웨이 경유면 — 네트워크 구간이 둘

```
[부하테스트기] ─세그먼트1─→ [게이트웨이] ─세그먼트2─→ [타겟 AP]
```

- **AP는 게이트웨이하고만 대화한다.** AP가 보는 커넥션은 전부 게이트웨이 IP에서 온 것.
  → AP의 동접 커넥션 수 = **게이트웨이의 백엔드 풀 크기** (내 vUser 수가 아님). `ss -s`로 실측.
- **AP의 대역폭 부하 = 페이로드 × TPS** (그대로 통과하니 vUser 수와 무관, 처리량에 비례).
- 두 세그먼트가 각각 병목이 될 수 있고, 같은 페이로드가 흐르므로 **양쪽 NIC 모두** (요청+응답)×TPS를
  감당해야 한다.

### 7-3. 타겟 서버(AP)에서 확인 — 중점

```bash
# 정적 확인
ethtool eth0 | grep Speed                        # NIC 속도 (발생기와 같은지)
cat /proc/net/bonding/bond0 2>/dev/null           # 본딩이면 7-1대로

# 테스트 중 실시간 (★ 네트워크 병목의 결정적 증거)
sar -n DEV 2 | grep eth0                           # rx/tx 사용률 (한계에 붙나)
ethtool -S eth0 | grep -iE "drop|discard|error|fifo"  # 패킷 버림 = 병목
cat /proc/net/dev | grep eth0                      # drop 컬럼 증가 확인
mpstat -P ALL 2 | grep all                         # %soft 높으면 pps 병목
ss -s                                              # 커넥션 수 (게이트웨이 풀 실측)
```

VM이면 `mpstat`의 `%steal`도 — 값이 크면 "서버 한계"가 아니라 물리 호스트/이웃 VM 간섭이다.

### 7-4. AP 성능을 정확히 보려면 — 베이스라인 비교

게이트웨이가 중간에 끼면 "AP가 느린지 게이트웨이가 느린지" 헷갈린다. 가르는 법:

```
테스트 A:  발생기 → AP 직접 (게이트웨이 우회)   → AP 순수 능력 (베이스라인)
테스트 B:  발생기 → 게이트웨이 → AP (실제 경로)  → 전체 성능
게이트웨이 오버헤드 = B 응답시간 − A 응답시간
```

가능하면 AP 내부 IP·포트로 직접 쏘는 경로를 확보해 A를 먼저 잡아둔다.

### 7-5. 판정 — 네트워크냐 서버냐

부하 중 타겟에서 아래를 동시에 본다:

| 관찰 | 의미 |
|---|---|
| NIC rx/tx가 속도 한계에 붙음 | 네트워크 대역폭 병목 |
| `ethtool -S` drop 증가 | 수신 버퍼 넘침 (pps / 커널 튜닝) |
| `%soft` 치솟음 | 패킷 처리로 CPU 소진 (pps 병목) |
| **셋 다 여유인데 응답 느림** | **네트워크 아님 → 서버 앱/CPU가 진짜 한계** (찾던 답) |

대역폭 계산(5장)으로 불가능 조합을 먼저 거르고, 이 실시간 관찰로 "지금 병목이 네트워크인지
서버인지"를 확정한다. 마지막 줄이 나와야 비로소 "서버 자체 용량"을 측정하는 것이다.
