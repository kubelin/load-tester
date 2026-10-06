// custom.go — 커스텀 규격 엔드포인트 (POST /custom)
//
// ★ 이 파일만 수정하면 된다. main.go는 건드릴 필요 없음.
// ★ 수정 후 컴파일:  cd jsonserver && go build -o dummy-json .        (폐쇄망: GOPROXY=off 붙이기)
// ★ 맥에서 RHEL용:  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dummy-json-linux-amd64 .
//
// 수정 구역은 [구멍 1] [구멍 2] [구멍 3] 세 곳. 나머지(맨 아래 배관부)는 손대지 않는다.
// 시간 값(inTime/outTime/procUs)은 배관부가 자동으로 채워서 응답 header에 넣어준다.
package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// ============================================================================
// [구멍 1] 요청 규격 — 받을 JSON의 header/data 필드를 여기에 정의
//   - 필드명은 반드시 대문자로 시작 (소문자면 JSON에서 안 읽힘)
//   - `json:"..."` 태그가 실제 JSON 키 이름 (GO-GUIDE.md 2장 참고)
// ============================================================================

type CustomReqHeader struct {
	MdSect           string `json:"mdSect"`
	SvcID            string `json:"svcId"`
	UuID             string `json:"uuId"`
	TlgrPrgsNo       string `json:"tlgrPrgsNo"`
	UserIpAddr       string `json:"userIpAddr"`
	SmpNtcTrdgSect   string `json:"smpNtcTrdgSect"`
	TrdgDt           string `json:"trdgDt"`
	PcRqstTime       string `json:"pcRqstTime"`
	ClitRsrvPrt      string `json:"clitRsrvPrt"`
	TestSect         string `json:"testSect"`
	UserID           string `json:"userId"`
	MacAddr          string `json:"macAddr"`
	LangTyp          string `json:"langTyp"`
	ScrnNo1          string `json:"scrnNo1"`
	ScrnNo2          string `json:"scrnNo2"`
	UserIpAddrTelno  string `json:"userIpAddrTelno"`
	BrnhCd           string `json:"brnhCd"`
	UpprDprtCd       string `json:"upprDprtCd"`
	AcngUnitCd       string `json:"acngUnitCd"`
	PrevAfteRqstSect string `json:"prevAfteRqstSect"`
	PrevAfteDtaSect  string `json:"prevAfteDtaSect"`
	DprtSectCd       string `json:"dprtSectCd"`
}

type InRec1 struct {
	UserPswd string `json:"USER_PSWD"`
	UserID   string `json:"USER_ID"`
	EmalAdrs string `json:"EMAL_ADRS"`
	UserIP   string `json:"USER_IP"`
	Mac      string `json:"MAC"`
}

type CustomReqData struct {
	InRec1 InRec1 `json:"InRec1"`
}

type CustomRequest struct {
	Header CustomReqHeader `json:"header"`
	Data   CustomReqData   `json:"data"`
}

// ============================================================================
// [구멍 2] 응답 규격 — 돌려줄 JSON의 header/data 필드를 여기에 정의
//   - 응답 header = 요청 header 전체 에코(임베딩) + 결과/시간 필드
//   - ResCode/ResMsg 는 [구멍 3]에서, InTime/OutTime/ProcUs 는 배관부가 채운다 (지우지 말 것)
// ============================================================================

type CustomResHeader struct {
	CustomReqHeader        // 요청 header 필드 전체가 같은 이름으로 펼쳐져 에코됨
	RspCd           string `json:"rspCd"`   // 응답 코드 ("0000" = 정상)
	RspMsg          string `json:"rspMsg"`  // 응답 메시지
	InTime          string `json:"inTime"`  // 자동: 요청 수신 시각 (RFC3339Nano)
	OutTime         string `json:"outTime"` // 자동: 응답 직전 시각
	ProcUs          int64  `json:"procUs"`  // 자동: 서버 처리시간 (μs)
}

type OutRec1 struct {
	UserID string `json:"USER_ID"`
	Status string `json:"STATUS"`
}

type CustomResData struct {
	OutRec1 OutRec1 `json:"OutRec1"`
	Pad     string  `json:"_pad,omitempty"` // 자동: ?respKB= 응답 팽창용 — 응답 data(본문)에 붙는다 (지우지 말 것)
}

type CustomResponse struct {
	Header CustomResHeader `json:"header"`
	Data   CustomResData   `json:"data"`
}

// ============================================================================
// [구멍 3] 처리 로직 — 요청(req)을 보고 응답(res)을 채운다
//   - req 는 파싱 완료 상태로 들어옴. res 의 시간 필드는 리턴 후 자동으로 덮임
//   - 지연 시뮬레이션이 필요하면 time.Sleep(50 * time.Millisecond) 처럼 사용
// ============================================================================

// defaultRespKB: 응답 data._pad 의 기본이자 최소 크기(KB). ?respKB= 를 안 주거나 이 값보다
// 작거나(0~7 포함) 숫자가 아니면 이 값이 적용된다 — JMeter 플랜의 -Jrespkb 기본값 0 도 8KB 로 나간다.
// 이 값 이상을 주면 그 크기로 덮어쓴다. 패딩을 아예 없애려면 이 상수를 0 으로.
const defaultRespKB = 8

func processCustom(req *CustomRequest, res *CustomResponse) {
	res.Header.CustomReqHeader = req.Header // 요청 header 그대로 에코

	res.Header.RspCd = "0000"
	res.Header.RspMsg = "정상"
	res.Data.OutRec1.UserID = req.Data.InRec1.UserID // 입력받은 USER_ID 그대로
	res.Data.OutRec1.Status = "정상"

	// TODO: 실제 로직이 필요하면 여기에. 예)
	// if req.Data.InRec1.UserID == "" {
	//     res.Header.RspCd = "4001"
	//     res.Header.RspMsg = "USER_ID 누락"
	//     res.Data.OutRec1.Status = "오류"
	// }
	// time.Sleep(50 * time.Millisecond)   // DB 50ms 흉내
}

// ============================================================================
// ▼▼▼ 배관부 — 여기서부터는 수정하지 않는다 ▼▼▼
// 시간 스탬프, JSON 파싱/직렬화, 에러 응답을 처리한다. main.go의 init()에서 등록됨.
// ============================================================================

func init() {
	http.HandleFunc("/custom", customHandler)
}

// customMaxBody: /custom 은 큰 요청 바디(부하 정찰용)를 받을 수 있도록 넉넉히 (64MB).
const customMaxBody = 64 << 20

// defaultPad: 기본 패딩은 요청마다 새로 만들지 않고 기동 시 한 번 만들어 재사용한다
// (문자열은 불변이라 고루틴 간 공유 안전, 고TPS 에서 할당·GC 부담 제거).
var defaultPad = strings.Repeat("x", defaultRespKB*1024)

// customEnvelope: header/data 키의 존재 여부를 구분하기 위한 1차 디코딩용 (규격 구조체로 바로
// 풀면 키가 빠져도 빈 값으로 채워져서 "없음" 과 "빈 값" 을 구분할 수 없다).
type customEnvelope struct {
	Header json.RawMessage `json:"header"`
	Data   json.RawMessage `json:"data"`
}

// isJSONObject: raw 가 존재하고 null 이 아니며 JSON 객체({...})인지.
func isJSONObject(raw json.RawMessage) bool {
	t := strings.TrimSpace(string(raw))
	return len(t) > 0 && t[0] == '{'
}

// decodeCustom: 바디를 구조 검사한 뒤 req 에 채운다. 정상이면 ("", ""), 오류면 (rspCd, rspMsg).
func decodeCustom(body io.Reader, req *CustomRequest) (string, string) {
	var env customEnvelope
	switch err := json.NewDecoder(body).Decode(&env); {
	case err == io.EOF:
		return "9999", "EMPTY_BODY: request body required"
	case err != nil:
		return "9999", "INVALID_JSON: " + err.Error()
	}
	if !isJSONObject(env.Header) {
		return "9999", "MISSING_HEADER: header object required"
	}
	if !isJSONObject(env.Data) {
		return "9999", "MISSING_DATA: data object required"
	}
	if err := json.Unmarshal(env.Header, &req.Header); err != nil {
		return "9999", "INVALID_HEADER: " + err.Error()
	}
	if err := json.Unmarshal(env.Data, &req.Data); err != nil {
		return "9999", "INVALID_DATA: " + err.Error()
	}
	return "", ""
}

func customHandler(w http.ResponseWriter, r *http.Request) {
	// 전문 규격 엔드포인트 — POST 만 받는다. 그 외 메서드는 405 (액세스 로그에도 남기지 않음).
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed: use POST", http.StatusMethodNotAllowed)
		return
	}
	in := time.Now()

	var req CustomRequest
	var res CustomResponse
	// 전문 구조 검사 — 아래 중 하나라도 걸리면 9999 (패딩 없는 작은 오류 전문):
	//   EMPTY_BODY      바디 없음
	//   INVALID_JSON    JSON 문법 오류
	//   MISSING_HEADER  "header" 객체 없음(또는 null·객체 아님)
	//   MISSING_DATA    "data" 객체 없음(또는 null·객체 아님)
	// header/data 가 빈 객체({})면 구조는 갖춘 것으로 보고 통과시킨다 — 개별 필드 필수 검사는
	// [구멍 3] processCustom 에서 업무 코드(예: 4001)로 처리한다.
	rspCd, rspMsg := decodeCustom(http.MaxBytesReader(w, r.Body, customMaxBody), &req)
	parsed := rspCd == ""
	if parsed {
		processCustom(&req, &res)
	} else {
		res.Header.RspCd = rspCd
		res.Header.RspMsg = rspMsg
	}

	// 부하 정찰 레버 (쿼리 파라미터, 게이트웨이가 백엔드로 전달해야 함):
	//   ?delay=200ms  서버 처리 지연 (in-flight 유지 → 커넥션/버퍼 누적)
	//   ?respKB=5120  응답을 N KB로 팽창 (게이트웨이가 큰 응답 버퍼링 → direct memory 압박)
	//                 생략·defaultRespKB 미만·잘못된 값이면 defaultRespKB(위 [구멍 3] 상단) 적용
	//                 파싱 실패(9999 EMPTY_BODY/INVALID_JSON) 응답에는 패딩을 붙이지 않는다
	if d := r.URL.Query().Get("delay"); d != "" {
		if dur, perr := time.ParseDuration(d); perr == nil && dur > 0 && dur <= 30*time.Second {
			time.Sleep(dur)
		}
	}
	kb := defaultRespKB
	if q := r.URL.Query().Get("respKB"); q != "" {
		if v, perr := strconv.Atoi(q); perr == nil && v >= defaultRespKB && v <= 65536 {
			kb = v
		}
	}
	switch {
	case !parsed:
		// 오류 전문은 작게 나간다
	case kb == defaultRespKB:
		res.Data.Pad = defaultPad
	case kb > 0:
		res.Data.Pad = strings.Repeat("x", kb*1024)
	}

	out := time.Now()
	res.Header.InTime = in.Format(time.RFC3339Nano)
	res.Header.OutTime = out.Format(time.RFC3339Nano)
	res.Header.ProcUs = out.Sub(in).Microseconds()

	buf, _ := json.Marshal(res)
	w.Header().Set("Content-Type", "application/json")
	w.Write(buf)

	// 액세스 로그: rsp=<rspCd> 로 성공(0000)/실패 구분, resp=<응답 바이트> 로 respKB 크기 확인
	logAccess(r, in, out, r.ContentLength, int64(len(buf)), res.Header.RspCd)
}
