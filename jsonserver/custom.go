// custom.go — 커스텀 규격 엔드포인트 (POST /custom)
//
// 사내 전문 규격:
//
//	요청  {"header":{...고정 헤더...}, "data":{"inRec1":{...}}}
//	응답  header = 요청 header 그대로 에코 + rtrnCd/rsltMsg + inTime/outTime/procUs
//	      data   = 요청 data와 같은 레코드·필드 구성, 값은 랜덤 (inRec1 → outRec1)
//	HTTP 상태는 항상 200. 성공은 rtrnCd "000…", 실패는 "999…" (접두어 규격)
//
// ★ 이 파일만 수정하면 된다. main.go는 건드릴 필요 없음.
// ★ 수정 후 컴파일:  cd jsonserver && go build -o dummy-json .        (폐쇄망: GOPROXY=off 붙이기)
//
//	맥에서 RHEL용:  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w" -o dummy-json-linux-amd64 .
//
// 헤더는 map으로 받아 그대로 돌려주므로 헤더 필드가 바뀌어도(추가·삭제·타입 변경) 이 파일을 고칠 필요가 없다.
// data도 레코드 구조를 그대로 따라가며 랜덤을 채우므로 inRec1 필드가 바뀌어도 마찬가지다.
// 수정 구역은 [구멍 1] [구멍 2] [구멍 3] 세 곳. 나머지(맨 아래 배관부)는 손대지 않는다.
package main

import (
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// ============================================================================
// [구멍 1] 규격 상수 — 결과 코드 키/값, 레코드 이름 규칙
// ============================================================================

const (
	rtrnCdKey  = "rtrnCd"  // 응답 header의 결과 코드 키
	rsltMsgKey = "rsltMsg" // 응답 header의 결과 메시지 키
	rtrnOK     = "000"     // 성공 코드 (000으로 시작)
	rtrnFail   = "999"     // 실패 코드 (999로 시작)
)

// 요청 레코드명 → 응답 레코드명. inRec1 → outRec1, 그 외는 그대로.
func outRecName(in string) string {
	if strings.HasPrefix(in, "in") {
		return "out" + in[len("in"):]
	}
	return in
}

// ============================================================================
// [구멍 2] 요청/응답 형태 — 헤더는 규격 무관(map), data는 레코드명 → 내용
// ============================================================================

type CustomRequest struct {
	Header map[string]any `json:"header"`
	Data   map[string]any `json:"data"`
}

type CustomResponse struct {
	Header map[string]any `json:"header"`
	Data   map[string]any `json:"data"`
}

// ============================================================================
// [구멍 3] 처리 로직 — 요청(req)을 보고 응답(res)을 채운다
//   - res.Header 에 rtrnCd/rsltMsg 를 넣는다. 시간 필드는 배관부가 뒤에 덮어쓴다
//   - 실패 응답을 내려면 res.Header[rtrnCdKey] = rtrnFail + "xx" 처럼 접두어를 지킨다
// ============================================================================

func processCustom(req *CustomRequest, res *CustomResponse) {
	res.Header = req.Header // 요청 header 전체를 그대로 에코 (필드가 무엇이든)
	res.Header[rtrnCdKey] = rtrnOK
	res.Header[rsltMsgKey] = "정상"

	// 응답 data: 요청과 같은 레코드·필드 구성에 랜덤 값. inRec1 → outRec1
	res.Data = make(map[string]any, len(req.Data))
	for name, rec := range req.Data {
		res.Data[outRecName(name)] = randomize(rec)
	}

	// TODO: 실제 로직이 필요하면 여기에. 예)
	// if rec, ok := req.Data["inRec1"].(map[string]any); ok && rec["useYn"] == "N" {
	//     res.Header[rtrnCdKey] = rtrnFail + "1"
	//     res.Header[rsltMsgKey] = "미사용 코드"
	// }
}

// randomize: 값의 구조(객체/배열/타입)는 유지하고 내용만 랜덤으로 바꾼다.
//
//	문자열 → 같은 길이(최소 4)의 영숫자, 숫자 → 0~9999, 불리언 → 랜덤, null → null
func randomize(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, fv := range t {
			out[k] = randomize(fv)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, ev := range t {
			out[i] = randomize(ev)
		}
		return out
	case string:
		n := len(t)
		if n < 4 {
			n = 4
		}
		return randString(n)
	case float64: // JSON 숫자는 float64로 들어온다
		return rand.IntN(10000)
	case bool:
		return rand.IntN(2) == 1
	default:
		return v // nil 등
	}
}

const randChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

func randString(n int) string {
	b := make([]byte, n)
	for i := range b {
		b[i] = randChars[rand.IntN(len(randChars))]
	}
	return string(b)
}

// ============================================================================
// ▼▼▼ 배관부 — 여기서부터는 수정하지 않는다 ▼▼▼
// JSON 파싱/직렬화, 시간 스탬프, 부하 정찰 레버(delay/respKB/fail)를 처리한다. main.go의 init()에서 등록됨.
// ============================================================================

func init() {
	http.HandleFunc("/custom", customHandler)
}

// customMaxBody: /custom 은 큰 요청 바디(부하 정찰용)를 받을 수 있도록 넉넉히 (64MB).
const customMaxBody = 64 << 20

func customHandler(w http.ResponseWriter, r *http.Request) {
	in := time.Now()
	q := r.URL.Query()

	var req CustomRequest
	res := CustomResponse{Header: map[string]any{}, Data: map[string]any{}}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, customMaxBody)).Decode(&req); err != nil {
		res.Header[rtrnCdKey] = rtrnFail
		res.Header[rsltMsgKey] = "INVALID_JSON: " + err.Error()
	} else {
		if req.Header == nil {
			req.Header = map[string]any{}
		}
		processCustom(&req, &res)
	}

	// 부하 정찰 레버 (쿼리 파라미터, 게이트웨이가 백엔드로 전달해야 함):
	//   ?fail=0.01    요청의 1%를 실패 응답(rtrnCd 999, HTTP 200)으로 → 어설션/에러 집계 동작 확인
	//   ?delay=200ms  서버 처리 지연 (in-flight 유지 → 커넥션/버퍼 누적)
	//   ?respKB=5120  응답을 N KB로 팽창 (게이트웨이가 큰 응답 버퍼링 → direct memory 압박)
	if f := q.Get("fail"); f != "" {
		if p, perr := strconv.ParseFloat(f, 64); perr == nil && p > 0 && rand.Float64() < p {
			res.Header[rtrnCdKey] = rtrnFail
			res.Header[rsltMsgKey] = "FAIL_INJECTED"
		}
	}
	if d := q.Get("delay"); d != "" {
		if dur, perr := time.ParseDuration(d); perr == nil && dur > 0 && dur <= 30*time.Second {
			time.Sleep(dur)
		}
	}
	if s := q.Get("respKB"); s != "" {
		if kb, perr := strconv.Atoi(s); perr == nil && kb > 0 && kb <= 65536 {
			res.Header["_pad"] = strings.Repeat("x", kb*1024)
		}
	}

	out := time.Now()
	res.Header["inTime"] = in.Format(time.RFC3339Nano)
	res.Header["outTime"] = out.Format(time.RFC3339Nano)
	procUs := out.Sub(in).Microseconds()
	res.Header["procUs"] = procUs

	buf, _ := json.Marshal(res)
	w.Header().Set("Content-Type", "application/json")
	w.Write(buf)

	if logCh != nil {
		line := fmt.Sprintf("%s in=%d out=%d proc_us=%d bytes=%d\n",
			r.RemoteAddr, in.UnixMilli(), out.UnixMilli(), procUs, r.ContentLength)
		select {
		case logCh <- line:
		default:
			dropped.Add(1)
		}
	}
}
