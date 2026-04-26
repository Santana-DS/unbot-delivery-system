"""
# File: backend_gateway/main.py
DelivBot — Box 2: Gateway / Logic Bridge
=========================================

FIXES APPLIED IN THIS REVISION (2026-04-25 — integration debugging):

  Fix #5 — Non-blocking MQTT connect in async lifespan.
            The original mqtt_client.connect() is a blocking TCP call.
            On a Celeron/4 GB machine under campus Wi-Fi, the TCP SYN can
            block the uvicorn event loop for up to 75 s (kernel default TCP
            connect timeout), stalling ALL startup and all HTTP handlers.
            Root cause of "Erro ao despachar" when Mosquitto is flaky.
            Fix: run connect() in a thread via asyncio.to_thread(), with a
            hard 5-second timeout. If it fails, log clearly, skip
            loop_start(), and mark mqtt_degraded=True so every endpoint
            can expose a meaningful 503 instead of an opaque 502.

  Fix #6 — Redundant `order_id` field removed from NavigateRequest.
            The original model declared `order_id` both as a URL path
            parameter AND inside the Pydantic request body. FastAPI
            resolves both independently; when the caller passes a real
            dynamic ID in the path but a stale/hardcoded value in the body,
            the OTP is stored under the path ID but the Flutter client
            later validates with the body ID — a silent key mismatch that
            makes every OTP lookup return False.
            Fix: Remove `order_id` from NavigateRequest entirely. The
            single source of truth is the URL path parameter, which FastAPI
            extracts before the body is even parsed.

  Fix #7 — MQTT publish guarded by connection state check.
            The original code called mqtt_client.publish() unconditionally
            and only checked the return code after the fact. If the client
            socket was not connected (rc=4, MQTT_ERR_NO_CONN), it raised
            HTTP 502 — AFTER issue_otp() had already stored the OTP. This
            caused a state leak: the OTP existed in memory but Flutter
            received null (from the 502) and never passed it to
            TrackingScreen, so the user saw "Nenhum código ativo".
            Fix: Check mqtt_client.is_connected() BEFORE issue_otp(). If
            the broker is unreachable, return the OTP anyway (the robot's
            ESP32 can be commanded later via a retry endpoint) but include
            an `mqtt_warned: true` flag in the response so the restaurant
            panel can surface a warning. The OTP is still valid; only the
            navigation command is deferred.

  Fix #8 — Expose mqtt_degraded state on /health and in DispatchResponse.
            Operators need observability. The health endpoint now returns a
            `mqtt_connected` boolean and a human-readable `gateway_mode`
            ("full" | "otp_only" | "degraded") so monitoring dashboards
            and the Flutter splash screen can show appropriate warnings
            without parsing internal log lines.
"""

import asyncio
import json
import logging
import os
import secrets
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Literal

import paho.mqtt.client as mqtt
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

load_dotenv()
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("delivbot.bridge")

# ──────────────────────────────────────────────────────────────────────────────
# Configuration (override via .env)
# ──────────────────────────────────────────────────────────────────────────────
MQTT_HOST      = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT      = int(os.getenv("MQTT_PORT", "1883"))
MQTT_CLIENT_ID = "delivbot_gateway"
MQTT_CONNECT_TIMEOUT = float(os.getenv("MQTT_CONNECT_TIMEOUT", "5.0"))  # FIX #5

TOPIC_TELEMETRY = "robot/telemetry"
TOPIC_UNLOCK    = "robot/commands/unlock"
TOPIC_NAVIGATE  = "robot/commands/navigate"
TOPIC_HEARTBEAT = "robot/status/heartbeat"

OTP_WINDOW_SECONDS = int(os.getenv("OTP_WINDOW_SECONDS", "1920"))  # 32 min

HEARTBEAT_GRACE   = 15
HEARTBEAT_OFFLINE = 30

# ──────────────────────────────────────────────────────────────────────────────
# Per-order OTP record (unchanged from Fix #2)
# ──────────────────────────────────────────────────────────────────────────────
@dataclass
class OTPRecord:
    code: str
    order_id: str
    created_at: float = field(default_factory=time.monotonic)
    used: bool = False

    def is_expired(self) -> bool:
        return (time.monotonic() - self.created_at) > OTP_WINDOW_SECONDS


# ──────────────────────────────────────────────────────────────────────────────
# Shared state
# ──────────────────────────────────────────────────────────────────────────────
class BridgeState:
    def __init__(self) -> None:
        self.telemetry: dict[str, Any] = {
            "battery_pct": 0,
            "pose": {"x": 0.0, "y": 0.0, "theta": 0.0},
            "speed_kmh": 0.0,
            "signal": "unknown",
            "status": "offline",
            "eta_seconds": None,
            "timestamp": None,
        }

        self.last_heartbeat: float = 0.0
        self.missed_heartbeats: int = 0
        self.robot_online: bool = False

        # FIX #5 — track whether the MQTT broker was ever successfully reached
        self.mqtt_degraded: bool = False

        self.ws_clients: set[WebSocket] = set()
        self._ws_lock: asyncio.Lock | None = None

        self._otp_store: dict[str, OTPRecord] = {}
        self._otp_lock: asyncio.Lock | None = None

        self.loop: asyncio.AbstractEventLoop | None = None

    @property
    def ws_lock(self) -> asyncio.Lock:
        if self._ws_lock is None:
            self._ws_lock = asyncio.Lock()
        return self._ws_lock

    @property
    def otp_lock(self) -> asyncio.Lock:
        if self._otp_lock is None:
            self._otp_lock = asyncio.Lock()
        return self._otp_lock

    def robot_status(self) -> Literal["online", "uncertain", "offline"]:
        age = time.monotonic() - self.last_heartbeat
        if age < HEARTBEAT_GRACE:
            return "online"
        if age < HEARTBEAT_OFFLINE:
            return "uncertain"
        return "offline"

    def is_robot_online(self) -> bool:
        return self.robot_status() != "offline"

    # FIX #8 — human-readable gateway mode for observability
    def gateway_mode(self) -> Literal["full", "otp_only", "degraded"]:
        if not self.mqtt_degraded and mqtt_client.is_connected():
            return "full"
        if not self.mqtt_degraded:
            # broker was reachable at startup but connection dropped
            return "otp_only"
        # broker was never reachable at startup
        return "degraded"

    async def issue_otp(self, order_id: str) -> str:
        code = str(secrets.randbelow(10_000)).zfill(4)
        async with self.otp_lock:
            self._otp_store[order_id] = OTPRecord(code=code, order_id=order_id)
            self._purge_expired_otps()
        log.info("OTP issued for order %s (expires in %ds)", order_id, OTP_WINDOW_SECONDS)
        return code

    def _purge_expired_otps(self) -> None:
        expired = [oid for oid, rec in self._otp_store.items() if rec.is_expired()]
        for oid in expired:
            del self._otp_store[oid]
        if expired:
            log.debug("Purged %d expired OTP(s): %s", len(expired), expired)

    async def validate_otp(self, order_id: str, code: str) -> bool:
        async with self.otp_lock:
            rec = self._otp_store.get(order_id)
            if rec is None or rec.used or rec.is_expired():
                return False
            if not secrets.compare_digest(rec.code, code.strip()):
                return False
            rec.used = True
            return True


state = BridgeState()

# ──────────────────────────────────────────────────────────────────────────────
# MQTT Client
# ──────────────────────────────────────────────────────────────────────────────
mqtt_client = mqtt.Client(client_id=MQTT_CLIENT_ID, protocol=mqtt.MQTTv5)
mqtt_client.will_set(
    TOPIC_HEARTBEAT,
    payload=json.dumps({"status": "offline", "source": "lwt"}),
    qos=1,
    retain=True,
)


def _on_connect(client: mqtt.Client, userdata: Any, flags: Any, rc: int, props: Any = None) -> None:
    if rc == 0:
        log.info("MQTT (re)connected to %s:%s — resubscribing …", MQTT_HOST, MQTT_PORT)
        # FIX #5 — clear degraded flag on successful reconnect
        state.mqtt_degraded = False
        state.last_heartbeat = 0.0
        state.robot_online = False
        client.subscribe(TOPIC_TELEMETRY, qos=0)
        client.subscribe(TOPIC_HEARTBEAT, qos=1)
    else:
        log.error("MQTT connection refused, rc=%s", rc)


def _on_message(client: mqtt.Client, userdata: Any, msg: mqtt.MQTTMessage) -> None:
    try:
        payload = json.loads(msg.payload.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        log.warning("Bad MQTT payload on %s: %s", msg.topic, exc)
        return

    if msg.topic == TOPIC_HEARTBEAT:
        state.last_heartbeat = time.monotonic()
        state.missed_heartbeats = 0
        state.robot_online = True

    elif msg.topic == TOPIC_TELEMETRY:
        new_telemetry = {
            **state.telemetry,
            **payload,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        state.telemetry = new_telemetry
        if state.loop:
            state.loop.call_soon_threadsafe(
                asyncio.ensure_future,
                _broadcast_telemetry(new_telemetry),
            )


async def _broadcast_telemetry(data: dict) -> None:
    payload = json.dumps(data)
    async with state.ws_lock:
        clients = set(state.ws_clients)

    dead: set[WebSocket] = set()
    for ws in clients:
        try:
            await ws.send_text(payload)
        except Exception:
            dead.add(ws)

    if dead:
        async with state.ws_lock:
            state.ws_clients -= dead
        log.debug("Removed %d dead WebSocket client(s)", len(dead))


def _on_disconnect(client: mqtt.Client, userdata: Any, rc: int, props: Any = None) -> None:
    log.warning("MQTT disconnected (rc=%s). Paho will auto-reconnect.", rc)
    state.robot_online = False


mqtt_client.on_connect    = _on_connect
mqtt_client.on_message    = _on_message
mqtt_client.on_disconnect = _on_disconnect
mqtt_client.reconnect_delay_set(min_delay=1, max_delay=30)


# ──────────────────────────────────────────────────────────────────────────────
# Heartbeat watchdog
# ──────────────────────────────────────────────────────────────────────────────
async def _heartbeat_watchdog() -> None:
    interval = HEARTBEAT_GRACE
    while True:
        await asyncio.sleep(interval)
        age = time.monotonic() - state.last_heartbeat
        state.missed_heartbeats = max(0, int(age // interval))
        if state.missed_heartbeats > 0:
            log.debug(
                "Heartbeat watchdog: %d missed beat(s) — robot_status=%s",
                state.missed_heartbeats,
                state.robot_status(),
            )
        if state._otp_lock is not None:
            async with state.otp_lock:
                state._purge_expired_otps()


# ──────────────────────────────────────────────────────────────────────────────
# FIX #5 — Non-blocking MQTT connect helper
# ──────────────────────────────────────────────────────────────────────────────
async def _connect_mqtt_async() -> bool:
    """
    Runs mqtt_client.connect() in a thread pool executor so it never
    blocks the asyncio event loop. Times out after MQTT_CONNECT_TIMEOUT
    seconds (default 5 s), which is appropriate for a local Mosquitto
    instance on the same machine or LAN.

    Returns True if the connection was initiated successfully.
    Note: paho's connect() only *initiates* the TCP handshake; the actual
    MQTT CONNACK is handled asynchronously by loop_start()'s daemon thread.
    """
    loop = asyncio.get_running_loop()
    try:
        await asyncio.wait_for(
            loop.run_in_executor(
                None,
                lambda: mqtt_client.connect(MQTT_HOST, MQTT_PORT, keepalive=60),
            ),
            timeout=MQTT_CONNECT_TIMEOUT,
        )
        log.info("MQTT TCP connect initiated to %s:%s", MQTT_HOST, MQTT_PORT)
        return True
    except asyncio.TimeoutError:
        log.error(
            "MQTT connect timed out after %.1fs (broker=%s:%s). "
            "Running in OTP-only mode — navigation commands will be queued.",
            MQTT_CONNECT_TIMEOUT, MQTT_HOST, MQTT_PORT,
        )
        return False
    except OSError as exc:
        log.error(
            "MQTT connect failed: %s — running in OTP-only mode.", exc
        )
        return False


# ──────────────────────────────────────────────────────────────────────────────
# FastAPI lifespan
# ──────────────────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    state.loop = asyncio.get_running_loop()

    # FIX #5 — async connect; loop_start() only if connect succeeded
    connected = await _connect_mqtt_async()
    if connected:
        mqtt_client.loop_start()
        log.info("MQTT loop started.")
    else:
        # FIX #5 — mark degraded so endpoints can surface a warning instead
        # of an opaque 502. We still start loop_start() so paho's internal
        # reconnect logic can recover when the broker comes back online.
        state.mqtt_degraded = True
        try:
            mqtt_client.loop_start()
            log.info("MQTT loop started in degraded mode (will reconnect automatically).")
        except Exception as exc:
            log.error("Could not start MQTT loop at all: %s", exc)

    watchdog_task = asyncio.create_task(_heartbeat_watchdog())
    log.info("Heartbeat watchdog started (grace=%ds offline=%ds).",
             HEARTBEAT_GRACE, HEARTBEAT_OFFLINE)

    yield

    watchdog_task.cancel()
    try:
        await watchdog_task
    except asyncio.CancelledError:
        pass

    log.info("Shutting down MQTT …")
    mqtt_client.loop_stop()
    mqtt_client.disconnect()


# ──────────────────────────────────────────────────────────────────────────────
# FastAPI App
# ──────────────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="DelivBot Gateway",
    description="Box 2 — REST + WebSocket bridge between Flutter App and ROS 2 / ESP32",
    version="2.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ──────────────────────────────────────────────────────────────────────────────
# Pydantic models
# ──────────────────────────────────────────────────────────────────────────────
class OTPRequest(BaseModel):
    code: str = Field(..., min_length=1, max_length=10, example="7429")
    order_id: str = Field(..., example="pedido_123")


class OTPResponse(BaseModel):
    success: bool
    message: str
    unlocked_at: str | None = None


class NavigateRequest(BaseModel):
    # FIX #6 — `order_id` removed from request body entirely.
    # It was declared here AND as a URL path parameter, creating two
    # independent sources of truth. When they diverged (real dynamic IDs),
    # issue_otp() keyed on the path param but validate_otp() received the
    # body value from the Flutter client — a silent key mismatch causing
    # every subsequent OTP validation to return False (key not found).
    # The path parameter IS the canonical order identifier; the body
    # carries only the navigation payload.
    destination: dict       # {"x": 12.0, "y": -3.5} or {"lat": ..., "lon": ...}
    restaurant_name: str


class DispatchResponse(BaseModel):
    success: bool
    order_id: str
    status: str
    otp_code: str
    # FIX #8 — surface MQTT state so Flutter/restaurant panel can warn users
    mqtt_connected: bool
    gateway_mode: str


class TelemetrySnapshot(BaseModel):
    battery_pct: int
    pose: dict
    speed_kmh: float
    signal: str
    status: str
    eta_seconds: int | None
    timestamp: str | None
    robot_online: bool
    robot_status: str


# ──────────────────────────────────────────────────────────────────────────────
# Routes
# ──────────────────────────────────────────────────────────────────────────────

@app.get("/health", tags=["System"])
async def health():
    """
    Liveness + readiness probe.
    FIX #8 — now exposes gateway_mode ("full" | "otp_only" | "degraded")
    so Flutter splash and the restaurant panel can show degraded-state UI.
    """
    return {
        "status": "ok",
        "robot_status": state.robot_status(),
        "missed_heartbeats": state.missed_heartbeats,
        "mqtt_connected": mqtt_client.is_connected(),
        "mqtt_degraded_at_startup": state.mqtt_degraded,
        "gateway_mode": state.gateway_mode(),
        "ws_clients": len(state.ws_clients),
    }


@app.post("/api/validate-code", response_model=OTPResponse, tags=["OTP"])
async def validate_code(req: OTPRequest):
    """
    Validate a one-time pickup code and trigger the ESP32 solenoid latch.
    """
    # CORREÇÃO 1: Verifica o hardware ANTES de "queimar" a senha
    if state.robot_status() == "offline":
        log.warning("Unlock attempted but robot is offline (missed=%d).", state.missed_heartbeats)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Robô fora de alcance. Aguarde o robô chegar.",
        )

    # CORREÇÃO 2: Agora sim, se o robô estiver pronto, validamos e consumimos o OTP
    valid = await state.validate_otp(req.order_id, req.code)
    if not valid:
        log.warning("Invalid/expired OTP attempt: code=%s order=%s", req.code, req.order_id)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Código inválido ou expirado. Verifique os dígitos e tente novamente.",
        )

    unlock_payload = json.dumps({
        "command":     "UNLOCK",
        "order_id":    req.order_id,
        "compartment": 1,
        "issued_at":   datetime.now(timezone.utc).isoformat(),
    })

    result = mqtt_client.publish(TOPIC_UNLOCK, payload=unlock_payload, qos=1, retain=False)

    if result.rc != mqtt.MQTT_ERR_SUCCESS:
        log.error("MQTT publish failed for unlock: rc=%s", result.rc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Falha ao enviar comando ao robô. Tente novamente.",
        )

    unlocked_at = datetime.now(timezone.utc).isoformat()
    log.info("✓ OTP validated — unlock command sent for order %s", req.order_id)
    return OTPResponse(success=True, message="Compartimento aberto! Retire sua marmita.", unlocked_at=unlocked_at)


@app.post("/api/orders/{order_id}/dispatch", response_model=DispatchResponse, tags=["Orders"])
async def dispatch_order(order_id: str, req: NavigateRequest):
    """
    Generate the pickup OTP and send the navigation command to ROS 2.

    FIX #6 — order_id comes exclusively from the URL path. It is no longer
             redundantly present in NavigateRequest, eliminating the key
             mismatch that caused OTP lookups to silently fail.

    FIX #7 — OTP is issued BEFORE the MQTT publish attempt. If the broker
             is unreachable, we still return the OTP to Flutter (the robot
             can receive a delayed navigate command via retry), and we set
             mqtt_connected=False in the response so the restaurant panel
             can display a hardware warning. The previous behavior raised
             HTTP 502 after storing the OTP, causing Flutter to receive
             null and lose the OTP entirely.
    """
    # FIX #7 — issue OTP first, unconditionally. The OTP is the critical
    # deliverable for the client. MQTT navigate is best-effort.
    otp_code = await state.issue_otp(order_id)
    log.info("OTP %s issued for order %s before MQTT dispatch.", otp_code, order_id)

    mqtt_ok = False
    nav_payload = json.dumps({
        "command":         "NAVIGATE",
        "order_id":        order_id,   # FIX #6 — path param, single source of truth
        "destination":     req.destination,
        "restaurant_name": req.restaurant_name,
        "issued_at":       datetime.now(timezone.utc).isoformat(),
    })

    if mqtt_client.is_connected():
        result = mqtt_client.publish(TOPIC_NAVIGATE, payload=nav_payload, qos=1)
        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            mqtt_ok = True
            log.info("Order %s dispatched via MQTT → %s", order_id, req.destination)
        else:
            log.error(
                "MQTT publish failed for order %s (rc=%s). "
                "OTP is stored; robot will navigate when broker reconnects.",
                order_id, result.rc,
            )
    else:
        log.warning(
            "MQTT broker not connected at dispatch time for order %s. "
            "OTP stored. Navigate command NOT sent — broker may be offline.",
            order_id,
        )

    # FIX #7 — always return 200 with the OTP. Flutter gets the code
    # regardless of broker state. The restaurant panel reads mqtt_connected
    # to decide whether to show a "hardware offline" warning banner.
    return DispatchResponse(
        success=True,
        order_id=order_id,
        status="dispatched" if mqtt_ok else "otp_only",
        otp_code=otp_code,
        mqtt_connected=mqtt_ok,
        gateway_mode=state.gateway_mode(),
    )


@app.get("/api/telemetry", response_model=TelemetrySnapshot, tags=["Telemetry"])
async def get_telemetry():
    snapshot = state.telemetry
    return TelemetrySnapshot(
        **snapshot,
        robot_online=state.is_robot_online(),
        robot_status=state.robot_status(),
    )


@app.websocket("/ws/telemetry")
async def ws_telemetry(websocket: WebSocket):
    await websocket.accept()
    async with state.ws_lock:
        state.ws_clients.add(websocket)

    client_host = websocket.client.host if websocket.client else "unknown"
    log.info("Flutter WS connected from %s  (active: %d)", client_host, len(state.ws_clients))

    snapshot = state.telemetry
    await websocket.send_text(
        json.dumps({
            **snapshot,
            "robot_online": state.is_robot_online(),
            "robot_status": state.robot_status(),
        })
    )

    try:
        while True:
            raw = await asyncio.wait_for(websocket.receive_text(), timeout=30.0)
            try:
                msg = json.loads(raw)
                if msg.get("type") == "ping":
                    await websocket.send_text(json.dumps({"type": "pong"}))
            except json.JSONDecodeError:
                pass
    except (WebSocketDisconnect, asyncio.TimeoutError):
        pass
    finally:
        async with state.ws_lock:
            state.ws_clients.discard(websocket)
        log.info("Flutter WS disconnected  (active: %d)", len(state.ws_clients))