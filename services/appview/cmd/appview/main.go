package main

import (
	"context"
	appview "github.com/stygian-tech/the-social-wire/services/appview/internal/runtime"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	env := map[string]string{}
	for _, value := range os.Environ() {
		key, text, ok := strings.Cut(value, "=")
		if ok {
			env[key] = text
		}
	}
	host, err := appview.NewHost(ctx, env)
	if err != nil {
		log.Print("AppView startup failed: ", err)
		os.Exit(1)
	}
	if err = host.Run(ctx); err != nil {
		shutdown, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		_ = host.Close(shutdown)
		cancel()
		log.Print("AppView stopped with a runtime error")
		os.Exit(1)
	}
}
