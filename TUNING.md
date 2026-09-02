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

- **네트워크 대역폭**: 응답 100KB × 20,000 TPS = 16Gbps. NIC/스위치가 감당하는지 먼저 계산
- **발생기 CPU 포화**: 커널이 아니라 부하 설계 문제 → 캘리브레이션으로 상한 실측 후 70~80%로 운용
- **WAS 애플리케이션 설정**: 워커 스레드풀, keep-alive 정책, DB 커넥션 풀은 OS가 아닌 WAS/앱에서
  (Tomcat `maxThreads`·`maxConnections`, JEUS 웹엔진 thread pool, WebtoB `MaxUser` 등)
