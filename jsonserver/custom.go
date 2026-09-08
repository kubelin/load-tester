// custom.go — 커스텀 규격 엔드포인트 (POST /custom)
//
// ★ 이 파일만 수정하면 된다. main.go는 건드릴 필요 없음.
// ★ 수정 후 컴파일:  cd jsonserver && go build -o dummy-json .        (폐쇄망: GOPROXY=off 붙이기)
//    맥에서 RHEL용:  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dummy-json-linux-amd64 .
//
// 수정 구역은 [구멍 1] [구멍 2] [구멍 3] 세 곳. 나머지(맨 아래 배관부)는 손대지 않는다.
// 시간 값(inTime/outTime/procUs)은 배관부가 자동으로 채워서 응답 header에 넣어준다.
package main

import (
	"encoding/json"
	"fmt"
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
	InTime          string `json:"inTime"`         // 자동: 요청 수신 시각 (RFC3339Nano)
	OutTime         string `json:"outTime"`        // 자동: 응답 직전 시각
	ProcUs          int64  `json:"procUs"`         // 자동: 서버 처리시간 (μs)
	Pad             string `json:"_pad,omitempty"` // 자동: ?respKB= 응답 팽창용 (지우지 말 것)
}

type OutRec1 struct {
	UserID string `json:"USER_ID"`
	Status string `json:"STATUS"`
}

type CustomResData struct {
	OutRec1 OutRec1 `json:"OutRec1"`
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

func customHandler(w http.ResponseWriter, r *http.Request) {
	in := time.Now()

	var req CustomRequest
	var res CustomResponse
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, customMaxBody)).Decode(&req); err != nil {
		res.Header.RspCd = "9999"
		res.Header.RspMsg = "INVALID_JSON: " + err.Error()
	} else {
		processCustom(&req, &res)
	}

	// 부하 정찰 레버 (쿼리 파라미터, 게이트웨이가 백엔드로 전달해야 함):
	//   ?delay=200ms  서버 처리 지연 (in-flight 유지 → 커넥션/버퍼 누적)
	//   ?respKB=5120  응답을 N KB로 팽창 (게이트웨이가 큰 응답 버퍼링 → direct memory 압박)
	if d := r.URL.Query().Get("delay"); d != "" {
		if dur, perr := time.ParseDuration(d); perr == nil && dur > 0 && dur <= 30*time.Second {
			time.Sleep(dur)
		}
	}
	if q := r.URL.Query().Get("respKB"); q != "" {
		if kb, perr := strconv.Atoi(q); perr == nil && kb > 0 && kb <= 65536 {
			res.Header.Pad = strings.Repeat("x", kb*1024)
		}
	}

	out := time.Now()
	res.Header.InTime = in.Format(time.RFC3339Nano)
	res.Header.OutTime = out.Format(time.RFC3339Nano)
	res.Header.ProcUs = out.Sub(in).Microseconds()

	buf, _ := json.Marshal(res)
	w.Header().Set("Content-Type", "application/json")
	w.Write(buf)

	if logCh != nil {
		line := fmt.Sprintf("%s in=%d out=%d proc_us=%d bytes=%d\n",
			r.RemoteAddr, in.UnixMilli(), out.UnixMilli(), res.Header.ProcUs, r.ContentLength)
		select {
		case logCh <- line:
		default:
			dropped.Add(1)
		}
	}
}
