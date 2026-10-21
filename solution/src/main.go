package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	greeting := os.Getenv("GREETING")
	if greeting == "" {
		greeting = "Hello from griffin"
	}

	secret := os.Getenv("SECRET_TOKEN")

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%s\n", greeting)
		if secret != "" {
			fmt.Fprintf(w, "Secret loaded: yes\n")
		} else {
			fmt.Fprintf(w, "Secret loaded: no\n")
		}
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
