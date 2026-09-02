package main

import (
	"log"
	"net/http"
)

func main() {
	http.HandleFunc("/ok", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("OK"))
	})
	log.Println("dummy server listening on :18080")
	log.Fatal(http.ListenAndServe(":18080", nil))
}
