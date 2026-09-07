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
	"net/http"
	"time"
)

// ============================================================================
// [구멍 1] 요청 규격 — 받을 JSON의 header/body 필드를 여기에 정의
//   - 필드명은 반드시 대문자로 시작 (소문자면 JSON에서 안 읽힘)
//   - `json:"..."` 태그가 실제 JSON 키 이름 (GO-GUIDE.md 2장 참고)
// ============================================================================

type CustomReqHeader struct {
	TxID    string `json:"txId"`
	SvcCode string `json:"svcCode"`
	// TODO: 필요한 요청 header 필드 추가
}

type CustomReqBody struct {
	OrderID string `json:"orderId"`
	Amount  int64  `json:"amount"`
	// TODO: 필요한 요청 body 필드 추가
}

type CustomRequest struct {
	Header CustomReqHeader `json:"header"`
	Body   CustomReqBody   `json:"body"`
}

// ============================================================================
// [구멍 2] 응답 규격 — 돌려줄 JSON의 header/body 필드를 여기에 정의
//   - InTime/OutTime/ProcUs 는 배관부가 자동으로 채운다 (지우지 말 것)
// ============================================================================

type CustomResHeader struct {
	TxID    string `json:"txId"`    // 배관부가 요청의 txId를 복사해줌
	ResCode string `json:"resCode"` // [구멍 3]에서 채움
	ResMsg  string `json:"resMsg"`  // [구멍 3]에서 채움
	InTime  string `json:"inTime"`  // 자동: 요청 수신 시각 (RFC3339Nano)
	OutTime string `json:"outTime"` // 자동: 응답 직전 시각
	ProcUs  int64  `json:"procUs"`  // 자동: 서버 처리시간 (μs)
	// TODO: 필요한 응답 header 필드 추가
}

type CustomResBody struct {
	OrderID string `json:"orderId"`
	Status  string `json:"status"`
	// TODO: 필요한 응답 body 필드 추가
}

type CustomResponse struct {
	Header CustomResHeader `json:"header"`
	Body   CustomResBody   `json:"body"`
}

// ============================================================================
// [구멍 3] 처리 로직 — 요청(req)을 보고 응답(res)을 채운다
//   - req 는 파싱 완료 상태로 들어옴. res 의 시간 필드는 리턴 후 자동으로 덮임
//   - 지연 시뮬레이션이 필요하면 time.Sleep(50 * time.Millisecond) 처럼 사용
// ============================================================================

func processCustom(req *CustomRequest, res *CustomResponse) {
	// 기본 예시 로직: 정상 응답 + 주문번호 에코
	res.Header.ResCode = "0000"
	res.Header.ResMsg = "SUCCESS"
	res.Body.OrderID = req.Body.OrderID
	res.Body.Status = "OK"

	// TODO: 여기에 실제 로직 작성. 예)
	// if req.Body.Amount > 1000000 {
	//     res.Header.ResCode = "4001"
	//     res.Header.ResMsg = "LIMIT_EXCEEDED"
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

func customHandler(w http.ResponseWriter, r *http.Request) {
	in := time.Now()

	var req CustomRequest
	var res CustomResponse
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&req); err != nil {
		res.Header.ResCode = "9999"
		res.Header.ResMsg = "INVALID_JSON: " + err.Error()
	} else {
		res.Header.TxID = req.Header.TxID
		processCustom(&req, &res)
	}

	out := time.Now()
	res.Header.InTime = in.Format(time.RFC3339Nano)
	res.Header.OutTime = out.Format(time.RFC3339Nano)
	res.Header.ProcUs = out.Sub(in).Microseconds()

	buf, _ := json.Marshal(res)
	w.Header().Set("Content-Type", "application/json")
	w.Write(buf)
}
