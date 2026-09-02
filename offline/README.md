# 폐쇄망 반입용 오프라인 패키지

## go1.27.1.linux-amd64.tar.gz

Go 공식 툴체인 (linux/amd64, ~67MB).
sha256: `63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445` (go.dev 공식 값과 대조 검증됨)

### RHEL 8 설치 (인터넷·yum·root 불필요)

```bash
# root 가능하면
sudo tar -C /usr/local -xzf go1.27.1.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# root 불가면 홈에 풀어도 됨
tar -C ~ -xzf go1.27.1.linux-amd64.tar.gz
export PATH=$PATH:~/go/bin
```

### 폐쇄망 내 빌드

```bash
cd jsonserver
GOPROXY=off go build -o dummy-json .   # 표준 라이브러리만 쓰므로 네트워크 불필요
```

문법은 저장소 루트의 `GO-GUIDE.md` 참고.
