# unbot-gateway

Go backend gateway for UnBot Delivery V2.0.

## Directory structure

```
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
```

## Quickstart

```bash
# 1. Install dependencies
go mod tidy

# 2. Copy and populate env file
cp .env.example .env
# Edit .env — set MQTT_HOST, MQTT_USER, MQTT_PASSWORD

# 3. Run the gateway
make run
```

## Verify the broker connection

With the gateway running, publish a mock heartbeat from any machine
that has mosquitto-clients installed:

```bash
mosquitto_pub \
  -h <vm-ip> -p 1883 \
  -u gateway -P <gateway-password> \
  -t robot/status/heartbeat \
  -m '{"source":"mock","status":"online"}'
```

The gateway log should print:
```json
{"level":"INFO","msg":"heartbeat received","topic":"robot/status/heartbeat","payload":"{...}"}
```

## Next tickets

- `internal/services/otp.go`  — OTP generation and validation logic
- `internal/api/dispatch.go`  — POST /api/orders/{id}/dispatch handler
- `internal/api/validate.go`  — POST /api/validate-code handler
- `internal/mqtt/publisher.go`— Typed publish helpers (navigate, unlock)
