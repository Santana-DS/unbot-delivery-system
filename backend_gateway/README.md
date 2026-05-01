unbot-gateway/
├── cmd/
│   └── gateway/
│       └── main.go          # Entry point — wiring only, no business logic
├── internal/
│   ├── config/
│   │   └── config.go        # Env var loading and validation
│   ├── mqtt/
│   │   └── client.go        # Paho wrapper, topic constants, stub handlers
│   └── api/
│       └── server.go        # HTTP server, /health route, future OTP routes
├── scripts/
│   └── setup_mosquitto.sh   # Ticket #1 — broker install and M2M auth setup
├── .env.example
├── go.mod
└── Makefile