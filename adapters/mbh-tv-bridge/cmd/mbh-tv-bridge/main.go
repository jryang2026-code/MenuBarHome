package main

import (
	"com.menubarhome.tv-bridge/internal/rpc"
	"log"
	"os"
)

func main() {
	log.SetOutput(os.Stderr)
	if err := rpc.New(os.Stdout, os.Getenv("MBH_DATA_DIR")).Serve(os.Stdin); err != nil {
		log.Printf("bridge stopped: %v", err)
		os.Exit(1)
	}
}
