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
	"os/signal"
	"path/filepath"
	"sort"
	"sync/atomic"
	"syscall"
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

// accessLogger owns the access log output. Exactly one goroutine (run) touches
// the file, so rotation and reopen need no locking: they happen between writes.
type accessLogger struct {
	dir      string // "" = write to stdout, no rotation
	maxBytes int64  // rotate when the current file would exceed this; 0 = never
	maxFiles int    // keep at most this many access_*.log files in dir; 0 = keep all

	out     *os.File
	w       *bufio.Writer
	written int64
	reopen  chan os.Signal // SIGHUP: close and open a fresh file (logrotate friendly)
	stop    chan os.Signal // SIGTERM/SIGINT: flush and exit
}

// openFile creates a new timestamped log file. If two rotations land in the
// same second, a numeric suffix keeps the files apart.
func (l *accessLogger) openFile() error {
	stamp := time.Now().Format("20060102_150405")
	name := filepath.Join(l.dir, "access_"+stamp+".log")
	for i := 1; ; i++ {
		if _, err := os.Stat(name); os.IsNotExist(err) {
			break
		}
		name = filepath.Join(l.dir, fmt.Sprintf("access_%s_%d.log", stamp, i))
	}
	f, err := os.OpenFile(name, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	l.out = f
	l.w = bufio.NewWriterSize(f, 256*1024)
	l.written = 0
	log.Printf("access log -> %s", name)
	return nil
}

// rotate flushes and closes the current file, opens a new one and prunes old
// files. On failure the current file stays open so no lines are lost.
func (l *accessLogger) rotate() {
	l.w.Flush()
	old := l.out
	if err := l.openFile(); err != nil {
		fmt.Fprintf(os.Stderr, "access log: rotate failed, keeping current file: %v\n", err)
		l.out = old
		l.w = bufio.NewWriterSize(old, 256*1024)
		return
	}
	old.Close()
	l.prune()
}

// prune deletes the oldest access_*.log files beyond maxFiles. File names carry
// the creation timestamp, so lexical order is chronological order.
func (l *accessLogger) prune() {
	if l.maxFiles <= 0 {
		return
	}
	files, err := filepath.Glob(filepath.Join(l.dir, "access_*.log"))
	if err != nil || len(files) <= l.maxFiles {
		return
	}
	sort.Strings(files)
	for _, f := range files[:len(files)-l.maxFiles] {
		if f == l.out.Name() {
			continue
		}
		if err := os.Remove(f); err != nil {
			fmt.Fprintf(os.Stderr, "access log: prune %s: %v\n", f, err)
		}
	}
}

func (l *accessLogger) flush() {
	l.w.Flush()
	if d := dropped.Swap(0); d > 0 {
		fmt.Fprintf(os.Stderr, "access log: dropped %d lines\n", d)
	}
}

// run drains logCh into the buffered writer. Request handlers never block on
// I/O: lines are dropped (and counted) when the channel is full, so throughput
// is protected over log completeness.
func (l *accessLogger) run() {
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case line := <-logCh:
			if l.maxBytes > 0 && l.written+int64(len(line)) > l.maxBytes {
				l.rotate()
			}
			l.w.WriteString(line)
			l.written += int64(len(line))
		case <-tick.C:
			l.flush()
		case <-l.reopen:
			l.rotate()
		case sig := <-l.stop:
			// drain what is already queued, then exit with the conventional code
			for {
				select {
				case line := <-logCh:
					l.w.WriteString(line)
					continue
				default:
				}
				break
			}
			l.flush()
			l.out.Close()
			signal.Reset(sig)
			os.Exit(128 + int(sig.(syscall.Signal)))
		}
	}
}

// startAccessLogger wires the channel, the output and the signal handlers, then
// starts the single writer goroutine. dir=="" writes to stdout without rotation.
func startAccessLogger(dir string, maxMB, maxFiles int) error {
	l := &accessLogger{dir: dir, maxBytes: int64(maxMB) << 20, maxFiles: maxFiles}
	if dir == "" {
		l.out = os.Stdout
		l.w = bufio.NewWriterSize(os.Stdout, 256*1024)
		l.maxBytes = 0
	} else {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		if err := l.openFile(); err != nil {
			return err
		}
		l.prune()
		l.reopen = make(chan os.Signal, 1)
		signal.Notify(l.reopen, syscall.SIGHUP)
	}
	l.stop = make(chan os.Signal, 1)
	signal.Notify(l.stop, syscall.SIGTERM, syscall.SIGINT)
	logCh = make(chan string, 65536)
	go l.run()
	return nil
}

func main() {
	port := flag.Int("port", 18080, "listen port")
	accessLog := flag.Bool("accesslog", false, "record per-request in/out times (async, may drop under load)")
	logDir := flag.String("logdir", "", "write access log to <logdir>/access_YYYYMMDD_HHMMSS.log instead of stdout (implies -accesslog)")
	logMaxMB := flag.Int("logmaxmb", 100, "rotate the access log file when it exceeds this many MB (0 = never; -logdir only)")
	logMaxFiles := flag.Int("logmaxfiles", 10, "keep at most this many access_*.log files in -logdir, oldest deleted (0 = keep all)")
	flag.Parse()

	if *logDir != "" {
		if err := startAccessLogger(*logDir, *logMaxMB, *logMaxFiles); err != nil {
			log.Fatalf("logdir: %v", err)
		}
		*accessLog = true
	} else if *accessLog {
		startAccessLogger("", 0, 0)
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
	if *logDir != "" {
		log.Printf("dummy-json listening on %s (accesslog=file dir=%s rotate=%dMB keep=%d)",
			addr, *logDir, *logMaxMB, *logMaxFiles)
	} else {
		log.Printf("dummy-json listening on %s (accesslog=%v)", addr, *accessLog)
	}
	log.Fatal(http.ListenAndServe(addr, nil))
}
