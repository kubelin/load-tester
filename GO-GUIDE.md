# Go 문법 퀵 가이드 — dummy-json 수정용

`jsonserver/main.go`를 직접 고칠 때 필요한 만큼만 정리. Java와 다른 점 위주.

## 0. 수정 → 빌드 → 실행 (이것만 알아도 됨)

```bash
cd jsonserver
vi main.go
go build -o dummy-json .        # 문법 오류 있으면 여기서 파일:줄번호로 알려줌
./dummy-json -port 18080
```

폐쇄망에서 네트워크 시도 차단이 필요하면: `GOPROXY=off go build -o dummy-json .`

## 1. 변수 — 타입이 뒤에 붙고, := 로 축약

```go
var name string = "test"   // 정식 선언
name := "test"             // 축약 (함수 안에서만) — 타입 자동 추론
count := 0                 // int
price := 45000.0           // float64
ok := true                 // bool
```

- 세미콜론 없음, `public/private` 없음 — **대문자로 시작하면 공개, 소문자면 비공개**
- 선언하고 안 쓰면 컴파일 에러 (Java는 경고, Go는 에러)

## 2. 구조체 + JSON 태그 — 규격 수정 시 제일 많이 만질 곳

```go
type reply struct {
    InTime string `json:"inTime"`          // Go 필드명 ↔ JSON 키 매핑
    ProcUs int64  `json:"procUs"`
    Memo   string `json:"memo,omitempty"`  // omitempty: 빈 값이면 JSON에서 생략
}
```

- JSON 키를 바꾸려면 **백틱 안의 태그만** 수정 (`json:"recvTime"` 등)
- 필드 추가는 한 줄 추가 + 핸들러에서 값 채우기
- **필드명이 소문자면 JSON에 안 나옴** (비공개라서) — 반드시 대문자로 시작

중첩 JSON `{"header":{...},"body":{...}}` 형태가 필요하면:

```go
type header struct {
    TxID string `json:"txId"`
}
type reply struct {
    Header header `json:"header"`   // 구조체 안에 구조체
    Body   any    `json:"body"`     // any = 아무 타입 (Java의 Object)
}
```

## 3. JSON 변환

```go
// 구조체 → JSON 바이트
buf, err := json.Marshal(res)

// JSON 바이트 → 구조체 (요청 파싱할 때)
var req myRequest
err := json.Unmarshal(body, &req)   // & = 포인터로 넘김 (아래 6번)
```

`json.RawMessage` 타입은 "파싱하지 않고 원문 그대로 통과" — 현재 echo 필드가 이걸 씀.

## 4. 함수 — 리턴이 여러 개, 에러는 마지막 리턴값

```go
func add(a int, b int) int {          // (인자들) 리턴타입
    return a + b
}

// Go 특유: 값과 에러를 같이 리턴. try-catch가 없고 이 패턴이 전부다
body, err := io.ReadAll(r.Body)
if err != nil {                        // 에러 검사는 항상 이 3줄 패턴
    // 에러 처리
}
```

## 5. 제어문 — 조건에 괄호 없음, 반복은 for 하나뿐

```go
if count > 10 {            // ( ) 없음, { } 필수
    ...
} else if count > 5 {
    ...
}

for i := 0; i < 10; i++ { ... }   // 일반 for
for {  ... }                       // 무한 루프 (while true)

switch method {                    // break 불필요 (자동 break)
case "GET":
    ...
case "POST", "PUT":                // 여러 값 한번에
    ...
default:
    ...
}
```

## 6. 포인터 — & 와 * 두 개만

```go
x := 10
p := &x        // p는 x의 주소
*p = 20        // 주소가 가리키는 값 변경 → x가 20
```

실전에서는 `json.Unmarshal(body, &req)` 처럼 **"이 함수가 req를 채워넣게 하려고 & 붙인다"**
정도만 이해하면 충분. Java 객체는 원래 다 참조라 이 구분이 없었을 뿐.

## 7. 슬라이스(배열)와 맵

```go
items := []string{"a", "b"}        // 슬라이스 (가변 배열, Java ArrayList)
items = append(items, "c")         // 추가는 append (재대입 필요)

m := map[string]int{"a": 1}        // 맵 (Java HashMap)
m["b"] = 2
v, exists := m["a"]                // 키 존재 확인 겸 조회
```

## 8. HTTP 핸들러 패턴 — 엔드포인트 추가하는 법

```go
http.HandleFunc("/newpath", func(w http.ResponseWriter, r *http.Request) {
    // r: 요청 (r.Method, r.URL.Query().Get("key"), r.Body)
    // w: 응답 쓰는 곳
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(201)                  // 상태코드 (생략하면 200)
    w.Write([]byte(`{"ok":true}`))
})
```

main.go의 `/echo` 핸들러가 이 패턴 그대로다. 새 엔드포인트가 필요하면
`main()` 안에 위 블록을 복사해 붙이면 끝.

## 9. Java와 헷갈리기 쉬운 것 정리

| Java 습관 | Go에서는 |
|---|---|
| `String name = "x";` | `name := "x"` (타입 뒤, 세미콜론 없음) |
| `try { } catch { }` | `if err != nil { }` |
| `public` / `private` | 대문자 시작 / 소문자 시작 |
| 클래스 + 메서드 | 구조체 + 함수 (상속 없음) |
| `null` | `nil` |
| `new ArrayList<>()` | `[]string{}` |
| import 안 쓰면 경고 | **컴파일 에러** (에디터가 자동 정리: `gofmt`) |

## 10. 자주 하는 수정 예시

**응답에 서버 호스트명 추가:**

```go
import "os"                                  // import 블록에 추가

// reply 구조체에 필드 추가
Host string `json:"host"`

// 핸들러에서 값 채우기
h, _ := os.Hostname()
res.Host = h
```

수정 후 `go build` — 에러 메시지가 `main.go:줄번호: 설명` 형식으로 나오니
그 줄만 다시 보면 된다. 컴파일이 통과하면 대부분 그대로 동작한다.
