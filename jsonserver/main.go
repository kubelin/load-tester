// dummy-json: load-test target server.
// Receives JSON over HTTP, stamps inbound/outbound times, echoes back as JSON.
// Stdlib only; build with CGO_ENABLED=0 for a static binary that runs on RHEL 8.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync/atomic"
	"time"
)

type reply struct {
	InTime  string          `json:"inTime"`
	InMs    int64           `json:"inEpochMs"`
	OutTime string          `json:"outTime"`
	OutMs   int64           `json:"outEpochMs"`
	ProcUs  int64           `json:"procUs"`
	Echo    json.RawMessage `json:"echo,omitempty"`
	Error   string          `json:"error,omitempty"`
}

const maxBody = 1 << 20 // 1MB request body cap

var (
	logCh   chan string
	dropped atomic.Int64
)

// startAccessLogger writes access lines to stdout from a buffered channel so
// request handlers never block on I/O. Lines are dropped (and counted) if the
// channel fills up — throughput is protected over log completeness.
func startAccessLogger() {
	logCh = make(chan string, 65536)
	go func() {
		w := bufio.NewWriterSize(os.Stdout, 256*1024)
		flush := time.NewTicker(200 * time.Millisecond)
		defer flush.Stop()
		for {
			select {
			case line := <-logCh:
				w.WriteString(line)
			case <-flush.C:
				w.Flush()
				if d := dropped.Swap(0); d > 0 {
					fmt.Fprintf(os.Stderr, "access log: dropped %d lines\n", d)
				}
			}
		}
	}()
}

func main() {
	port := flag.Int("port", 18080, "listen port")
	accessLog := flag.Bool("accesslog", false, "print per-request in/out times to stdout (async, may drop under load)")
	flag.Parse()

	if *accessLog {
		startAccessLogger()
	}

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("OK"))
	})

	http.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		in := time.Now()

		body, err := io.ReadAll(io.LimitReader(r.Body, maxBody))
		res := reply{
			InTime: in.Format(time.RFC3339Nano),
			InMs:   in.UnixMilli(),
		}
		switch {
		case err != nil:
			res.Error = "body read failed: " + err.Error()
		case len(body) == 0:
			// no body (e.g. GET) — echo omitted
		case json.Valid(body):
			res.Echo = body
		default:
			res.Error = "request body is not valid JSON"
		}

		// optional simulated processing time, e.g. /echo?delay=50ms
		if d := r.URL.Query().Get("delay"); d != "" {
			if dur, perr := time.ParseDuration(d); perr == nil && dur > 0 && dur <= 30*time.Second {
				time.Sleep(dur)
			}
		}

		out := time.Now()
		res.OutTime = out.Format(time.RFC3339Nano)
		res.OutMs = out.UnixMilli()
		res.ProcUs = out.Sub(in).Microseconds()

		buf, _ := json.Marshal(res)
		w.Header().Set("Content-Type", "application/json")
		w.Write(buf)

		if logCh != nil {
			line := fmt.Sprintf("%s in=%d out=%d proc_us=%d bytes=%d\n",
				r.RemoteAddr, res.InMs, res.OutMs, res.ProcUs, len(body))
			select {
			case logCh <- line:
			default:
				dropped.Add(1)
			}
		}
	})

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("dummy-json listening on %s (accesslog=%v)", addr, *accessLog)
	log.Fatal(http.ListenAndServe(addr, nil))
}
