package main

import (
	"errors"
	"strings"
)

func parseArguments(env map[string]string, args []string) error {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "serve":
			if i != 0 {
				return errors.New("unexpected Gateway subcommand")
			}
		case "--port", "--hostname":
			flag := args[i]
			if i+1 >= len(args) || strings.HasPrefix(args[i+1], "--") {
				return errors.New("Gateway option requires a value")
			}
			i++
			key := "PORT"
			if flag == "--hostname" {
				key = "BIND_HOST"
			}
			env[key] = args[i]
		default:
			return errors.New("unknown Gateway argument")
		}
	}
	return nil
}
