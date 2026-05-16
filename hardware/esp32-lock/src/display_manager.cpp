// =============================================================================
// src/display_manager.cpp
//
// UnBot Delivery — OLED Display + QR Code Implementation (v3.0)
// -----------------------------------------------------------------------------
// See display_manager.h for the design contract and RAM budget analysis.
//
// RENDERING INVARIANT:
//   Every public method that draws something MUST call display.display() as its
//   last statement. The SSD1306 driver accumulates draw calls into a 1KB RAM
//   framebuffer; nothing is sent to the physical display until display() is
//   called. Forgetting this is the most common SSD1306 bug.
//
// FONT METRICS (Adafruit GFX default "Adafruit font", textSize 1):
//   Character width  : 6 px  (5px glyph + 1px spacing)
//   Character height : 8 px
//   At textSize 2: 12×16 px per character.
// =============================================================================

#include "display_manager.h"

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <qrcode.h>   // ricmoo/QRCode — provides qrcode_initText(), qrcode_getModule()

// =============================================================================
// Driver instance
// OLED_HEIGHT/4 = 16 for the 64px display — this is the SSD1306 constructor's
// "page height" parameter, required for the Adafruit driver internal buffer math.
// OLED_RESET = -1 tells the driver there is no dedicated reset pin; the module's
// RST is wired to EN (or VCC) and managed by the ESP32's power-on reset.
// =============================================================================
static Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// =============================================================================
// begin()
// =============================================================================
bool DisplayManager::begin() {
    // Initialise the I2C bus on the hardware-assigned pins.
    // Wire.begin(SDA, SCL) must be called before display.begin() because
    // Adafruit_SSD1306 calls Wire.beginTransmission() during initialisation.
    Wire.begin(OLED_SDA_PIN, OLED_SCL_PIN);

    // display.begin() sends the SSD1306 initialisation sequence over I2C.
    // Returns false if the device does not ACK — typically means wrong address
    // or SDA/SCL wiring fault.
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.printf("[DISPLAY] SSD1306 not found at I2C 0x%02X "
                      "(SDA=%d SCL=%d) — check wiring\n",
                      OLED_I2C_ADDR, OLED_SDA_PIN, OLED_SCL_PIN);
        _ready = false;
        return false;
    }

    display.setTextColor(SSD1306_WHITE);
    display.setTextWrap(false);   // Prevent GFX from wrapping at 128px — we
                                  // control layout manually via _drawCentredText.
    display.clearDisplay();
    display.display();

    _ready = true;
    Serial.printf("[DISPLAY] SSD1306 ready — %dx%d @ I2C 0x%02X\n",
                  OLED_WIDTH, OLED_HEIGHT, OLED_I2C_ADDR);
    return true;
}

// =============================================================================
// showQrCode()
// =============================================================================
void DisplayManager::showQrCode(const char* otp, const char* orderId) {
    if (!_ready) return;

    // ── Step 1: Generate QR matrix on the stack ───────────────────────────
    // qrcode_t holds metadata (version, size, pointer into the buffer).
    // qrcode_initText() fills the provided byte array with the module bitmap.
    // Stack cost: sizeof(QRCode) ≈ 8 bytes + buffer ≈ 70 bytes = ~78 bytes.
    QRCode qrcode;
    uint8_t qrData[qrcode_getBufferSize(QR_VERSION)];  // 70 bytes on the stack

    // qrcode_initText encodes an ASCII string. For a 4-digit OTP this always
    // succeeds at version 1 / ECC_MEDIUM. The return value is 0 on success.
    int8_t result = qrcode_initText(&qrcode, qrData, QR_VERSION, QR_ECC_LEVEL, otp);
    if (result != 0) {
        Serial.printf("[DISPLAY] QR encode failed (result=%d) for otp='%s'\n",
                      result, otp);
        showError("QR ENCODE ERR");
        return;
    }

    Serial.printf("[DISPLAY] QR generated — version %d, size %dx%d, "
                  "scale %d, offset (%d,%d)\n",
                  qrcode.version, qrcode.size, qrcode.size,
                  QR_MODULE_PX, QR_OFFSET_X, QR_OFFSET_Y);

    // ── Step 2: Render into framebuffer ───────────────────────────────────
    display.clearDisplay();

    // Nested loop: for each of the 21×21 QR modules, if the module is dark
    // (foreground), draw a QR_MODULE_PX × QR_MODULE_PX filled rectangle.
    // Light modules (background) are already clear from clearDisplay().
    //
    // The inner fillRect is the hot path — 21×21 = 441 iterations, each
    // potentially filling 9 pixels. At 128×64 this is ~3969 pixel writes
    // into RAM — completes in microseconds on the 240 MHz ESP32.
    for (uint8_t row = 0; row < qrcode.size; row++) {
        for (uint8_t col = 0; col < qrcode.size; col++) {
            if (qrcode_getModule(&qrcode, col, row)) {
                _drawModule(col, row);
            }
        }
    }

    // ── Step 3: Status text overlay ───────────────────────────────────────
    // The QR occupies rows 0–62 (63px tall at scale 3). Row 63 is 1px margin.
    // We overlay two text lines inside the left margin (x < QR_OFFSET_X = 32)
    // using 6px-wide chars. With textSize 1 we fit 5 chars in 32px.
    //
    // Layout for a centred display (QR is centred in 128px wide display):
    //   - "CÓDIGO" banner above or overlaid at y=0 using the 32px left strip.
    //   - orderId (last 6 chars) in the right strip if available.
    //
    // In practice, the strips are narrow (32px = 5 chars). We instead place
    // a text line BELOW the QR when vertical space permits, or skip it entirely
    // since the OTP digits are more useful than labels in the MVP.
    //
    // For the 128×64 display at scale=3 (QR_OFFSET_Y=0), we have 1px below
    // the QR — not enough for text. So we render the OTP digits in the
    // left strip (x 0–31) and order short-ID in right strip (x 96–127).
    // Each strip fits textSize=1 (6px wide) in portrait: 5 chars, 8px tall.
    // We render vertically centred in each strip.

    // Left strip: OTP digits, large (textSize 2 = 12×16px → 2 chars wide, 4px strip)
    // Better option: render OTP digits in the 1px strips is impractical.
    // MVP decision: skip overlay, show raw QR. The orderId is logged to Serial.
    // A future revision can add a 128×80 display with room for a text row.

    if (orderId && orderId[0] != '\0') {
        Serial.printf("[DISPLAY] QR shown — order: %s  otp: %s\n", orderId, otp);
    }

    // ── Step 4: Push framebuffer to physical display ──────────────────────
    display.display();
}

// =============================================================================
// showUnlockSuccess()
// =============================================================================
void DisplayManager::showUnlockSuccess(const char* orderId) {
    if (!_ready) return;

    display.clearDisplay();

    // ── 1. Ícone de Check (Menor e no topo: ocupa do Y=6 ao Y=26) ──────────
    // Reduzimos a espessura do traço (t de -1 a 1) para ficar mais elegante
    for (int8_t t = -1; t <= 1; t++) {
        display.drawLine(48, 14 + t, 60, 26 + t, SSD1306_WHITE); // Diagonal menor
        display.drawLine(60, 26 + t, 84,  6 + t, SSD1306_WHITE); // Diagonal maior
    }

    // ── 2. Texto "ABERTO!" (Centralizado no meio: ocupa do Y=32 ao Y=48) ───
    // textSize 2 = 12px de largura x 16px de altura. "ABERTO!" (7 chars) = 84px.
    // X offset = (128 - 84) / 2 = 22
    display.setTextSize(2);
    display.setCursor(22, 32);
    display.print(F("ABERTO!"));

    // ── 3. ID do Pedido (Rodapé: ocupa do Y=54 ao Y=62) ───────────────────
    if (orderId && orderId[0] != '\0') {
        display.setTextSize(1);
        const char* shortId = orderId;
        size_t len = strlen(orderId);
        if (len > 6) shortId = orderId + (len - 6);
        _drawCentredText(shortId, 54, 1);
    }

    display.setTextSize(1);  // Reseta para as próximas chamadas
    display.display();

    Serial.printf("[DISPLAY] Unlock success screen shown (order: %s)\n",
                  (orderId && orderId[0]) ? orderId : "—");
}

// =============================================================================
// showBooting()
// =============================================================================
void DisplayManager::showBooting() {
    if (!_ready) return;

    display.clearDisplay();

    // Brand name — textSize 2 = 12×16px, "UnBot" = 5 chars = 60px → x=34
    display.setTextSize(2);
    display.setCursor(34, 8);
    display.print(F("UnBot"));

    // Subtitle — textSize 1, "Delivery" = 8 chars × 6px = 48px → x=40
    display.setTextSize(1);
    _drawCentredText("Delivery", 30, 1);

    // Horizontal separator
    display.drawFastHLine(16, 40, 96, SSD1306_WHITE);

    // Status
    _drawCentredText("Conectando...", 48, 1);

    display.display();
}

// =============================================================================
// showConnected()
// =============================================================================
void DisplayManager::showConnected() {
    if (!_ready) return;

    display.clearDisplay();

    display.setTextSize(2);
    display.setCursor(16, 4);
    display.print(F("UnBot"));

    display.setTextSize(1);
    _drawCentredText("Delivery", 24, 1);

    display.drawFastHLine(16, 34, 96, SSD1306_WHITE);

    _drawCentredText("Aguardando", 40, 1);
    _drawCentredText("pedido...", 50, 1);

    display.display();
}

// =============================================================================
// showError()
// =============================================================================
void DisplayManager::showError(const char* msg) {
    if (!_ready) return;

    display.clearDisplay();

    // Warning icon — simple X
    display.drawLine(52, 16, 76, 40, SSD1306_WHITE);
    display.drawLine(76, 16, 52, 40, SSD1306_WHITE);

    display.setTextSize(1);
    _drawCentredText("ERRO", 44, 1);

    // Truncate msg to 21 chars (full display width at textSize 1)
    char buf[22];
    strncpy(buf, msg, 21);
    buf[21] = '\0';
    _drawCentredText(buf, 54, 1);

    display.display();
}

// =============================================================================
// _drawModule() — private
// =============================================================================
void DisplayManager::_drawModule(uint8_t col, uint8_t row) {
    // Each QR module maps to a QR_MODULE_PX × QR_MODULE_PX rectangle.
    // fillRect(x, y, w, h, colour) — x is horizontal, y is vertical (top=0).
    display.fillRect(
        QR_OFFSET_X + col * QR_MODULE_PX,   // pixel x
        QR_OFFSET_Y + row * QR_MODULE_PX,   // pixel y
        QR_MODULE_PX,                        // width
        QR_MODULE_PX,                        // height
        SSD1306_WHITE
    );
}

// =============================================================================
// _drawCentredText() — private
// =============================================================================
void DisplayManager::_drawCentredText(const char* text, uint8_t y, uint8_t textSize) {
    // Adafruit GFX default font: 6px per char at textSize 1.
    // At textSize N: (6*N) px per char.
    uint8_t charWidth = 6 * textSize;
    uint8_t strPixels = strlen(text) * charWidth;
    // Integer division gives left x such that text is horizontally centred.
    // If strPixels > OLED_WIDTH, x underflows (uint8_t wraps) — guard it.
    uint8_t x = (strPixels < OLED_WIDTH)
                    ? (OLED_WIDTH - strPixels) / 2
                    : 0;
    display.setTextSize(textSize);
    display.setCursor(x, y);
    display.print(text);
}
