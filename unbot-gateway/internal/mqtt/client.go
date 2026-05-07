// internal/mqtt/client.go
//
// Wraps paho.mqtt.golang with:
//   - Structured logging on every lifecycle event.
//   - Automatic reconnection via paho's built-in ConnectRetry.
//   - A clean Connect/Disconnect API so main.go stays thin.
//   - Stub message handlers for every topic the gateway owns, ready to be
//     wired to real business logic in the /services layer.
//
// CGNAT note: the 4G LTE router on the robot means the Pi must initiate
// outbound connections to this broker. This client (running on the cloud VM)
// is the passive receiver — it never dials the Pi directly. That constraint
// is fully satisfied by a standard broker subscription model.
package mqtt

import (
	"fmt"
	"log/slog"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"

	"unbot-gateway/internal/config"
)

// ── Topic constants ───────────────────────────────────────────────────────────
// Single source of truth for every MQTT topic the gateway touches.
// ESP32 firmware and the Pi telemetry node must use these exact strings.
const (
	TopicTelemetry      = "robot/telemetry"
	TopicHeartbeat      = "robot/status/heartbeat"
	TopicNavigate       = "robot/commands/navigate"
	TopicUnlock         = "robot/commands/unlock"
)

// Client is the gateway's MQTT facade.
// Use NewClient to construct; call Connect before publishing.
type Client struct {
	inner paho.Client
	cfg   *config.Config
	log   *slog.Logger
}

// NewClient builds a configured paho client but does not connect.
func NewClient(cfg *config.Config, log *slog.Logger) *Client {
	c := &Client{cfg: cfg, log: log}

	opts := paho.NewClientOptions()
	opts.AddBroker(cfg.BrokerURL())
	opts.SetClientID(cfg.MQTTClientID)
	opts.SetUsername(cfg.MQTTUser)
	opts.SetPassword(cfg.MQTTPassword)

	// Keep-alive: broker detects a dead gateway within 2× this window.
	opts.SetKeepAlive(30 * time.Second)

	// Paho reconnects automatically; handlers are re-subscribed in OnConnect.
	opts.SetConnectRetry(true)
	opts.SetConnectRetryInterval(5 * time.Second)
	opts.SetAutoReconnect(true)
	opts.SetMaxReconnectInterval(30 * time.Second)

	// Last-will so downstream consumers know the gateway went offline hard.
	opts.SetWill(
		TopicHeartbeat,
		`{"source":"gateway","status":"offline"}`,
		1,     // QoS 1 — at least once
		false, // non-retained; stale LWT should not survive a broker restart
	)

	opts.SetOnConnectHandler(c.onConnect)
	opts.SetConnectionLostHandler(c.onConnectionLost)
	opts.SetReconnectingHandler(c.onReconnecting)

	c.inner = paho.NewClient(opts)
	return c
}

// Connect initiates the broker connection and blocks until it succeeds or
// the timeout expires. Called once from main during startup.
func (c *Client) Connect() error {
	c.log.Info("connecting to MQTT broker", "url", c.cfg.BrokerURL())

	token := c.inner.Connect()
	if !token.WaitTimeout(15 * time.Second) {
		return fmt.Errorf("MQTT connect timed out after 15s (broker=%s)", c.cfg.BrokerURL())
	}
	if err := token.Error(); err != nil {
		return fmt.Errorf("MQTT connect failed: %w", err)
	}
	return nil
}

// Disconnect performs a clean MQTT DISCONNECT and waits up to 3s for
// in-flight messages to drain. Called from main's shutdown hook.
func (c *Client) Disconnect() {
	c.log.Info("disconnecting from MQTT broker")
	c.inner.Disconnect(3000) // quiesce millis
}

// Publish sends a message on the given topic at QoS 1.
// Returns an error if the publish token fails within 5s.
func (c *Client) Publish(topic string, payload []byte) error {
	token := c.inner.Publish(topic, 1, false, payload)
	if !token.WaitTimeout(5 * time.Second) {
		return fmt.Errorf("MQTT publish timed out on topic %q", topic)
	}
	return token.Error()
}

// ── Lifecycle callbacks ───────────────────────────────────────────────────────

func (c *Client) onConnect(client paho.Client) {
	c.log.Info("MQTT connected — subscribing to topics")
	c.subscribe(TopicTelemetry, 0, c.handleTelemetry)
	c.subscribe(TopicHeartbeat, 1, c.handleHeartbeat)
}

func (c *Client) onConnectionLost(_ paho.Client, err error) {
	c.log.Warn("MQTT connection lost — paho will reconnect automatically",
		"error", err)
}

func (c *Client) onReconnecting(_ paho.Client, _ *paho.ClientOptions) {
	c.log.Info("MQTT reconnecting...")
}

// subscribe is a helper that logs and fatals loudly if a subscription fails.
// Subscription failures during onConnect mean the gateway is deaf — it must
// not silently continue.
func (c *Client) subscribe(topic string, qos byte, handler paho.MessageHandler) {
	token := c.inner.Subscribe(topic, qos, handler)
	if !token.WaitTimeout(5 * time.Second) {
		c.log.Error("MQTT subscribe timed out", "topic", topic)
		return
	}
	if err := token.Error(); err != nil {
		c.log.Error("MQTT subscribe failed", "topic", topic, "error", err)
		return
	}
	c.log.Info("subscribed", "topic", topic, "qos", qos)
}

// ── Message handlers (mocks — wire to /services in next iteration) ────────────
//
// These are intentionally thin stubs. Each one logs the raw payload so the
// team can validate end-to-end message flow from the mock publisher before
// real hardware is available. Replace the log lines with service calls.

func (c *Client) handleTelemetry(_ paho.Client, msg paho.Message) {
	c.log.Info("telemetry received",
		"topic", msg.Topic(),
		"payload", string(msg.Payload()),
	)
	// TODO(services): parse into TelemetrySnapshot, broadcast via WebSocket.
}

func (c *Client) handleHeartbeat(_ paho.Client, msg paho.Message) {
	c.log.Info("heartbeat received",
		"topic", msg.Topic(),
		"payload", string(msg.Payload()),
	)
	// TODO(services): update robot online state, reset watchdog timer.
}
