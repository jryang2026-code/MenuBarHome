package main

import (
	"com.menubarhome.tv-bridge/internal/rpc"
	"log"
	"os"
)

func main() {
	log.SetOutput(os.Stderr)
	data := os.Getenv("MBH_DATA_DIR")
	if data == "" {
		data = "."
	}
	if err := rpc.New(os.Stdout, data).Serve(os.Stdin); err != nil {
		log.Printf("bridge stopped: %v", err)
		os.Exit(1)
	}
}
