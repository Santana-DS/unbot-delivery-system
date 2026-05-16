# UnBot Delivery — ESP32 Firmware (Módulo de Acionamento e Ecrã Dinâmico)

Este diretório contém o firmware em C++ (Framework Arduino via PlatformIO) responsável por gerir a tranca física (atuador) do UnBot e a interface visual do cliente (Ecrã OLED). Atua como um nó IoT edge, recebendo comandos diretos da nuvem AWS (Mosquitto) via MQTT.

## 🎯 A Evolução para MFA Ótico (v2.1)
Com a implementação da Autenticação de Múltiplos Fatores (MFA) por proximidade física, o robô deixou de ter um código QR impresso. O ESP32 agora gera e renderiza um Código QR dinâmico no ecrã OLED com a palavra-passe (OTP) exata daquele pedido no momento da entrega, garantindo máxima segurança.

## 🚀 Arquitetura e Funcionalidades
* **Conexão Resiliente:** Máquina de estados não-bloqueante (`MqttManager`) que gere a ligação Wi-Fi e MQTT em simultâneo. Possui reconexão automática e *backoff* exponencial.
* **Geração de QR Code *On-the-fly*:** Utiliza processamento otimizado na RAM do microcontrolador para converter strings em matrizes visuais no ecrã.
* **Proteção contra Replay Attacks:** Verifica o campo `issued_at` (Unix Timestamp) para descartar comandos desfasados retidos pelo broker.
* **Telemetria:** Publicação automática de *Heartbeat* (pulso de vida) a cada 30 segundos, informando o estado, *uptime* e uso de memória.

## 🔌 Setup de Hardware
O processamento corre em modo *non-blocking* para não pausar a rede enquanto o ecrã desenha ou a tranca abre.

* **Atuador/Tranca:** `GPIO 2` (O pino ficará em estado `HIGH` por exatamente **5000 ms** após comando validado).
* **Ecrã OLED (I2C):**
  * `SDA`: `GPIO 21`
  * `SCL`: `GPIO 22`

## ⚙️ Dependências (PlatformIO)
As dependências são geridas automaticamente pelo ficheiro `platformio.ini`. Adicionámos as bibliotecas gráficas e de geração de códigos QR:

```ini
knolleary/PubSubClient @ ^2.8.0
bblanchon/ArduinoJson @ ^7.4.3
ricmoo/QRCode @ ^0.0.1
adafruit/Adafruit SSD1306 @ ^2.5.7
adafruit/Adafruit GFX Library @ ^1.11.3
```

## 🔐 Configuração Inicial (Para a Equipe de Hardware)
As credenciais de Wi-Fi e AWS **não estão no controlo de versão** por questões de segurança. 
Antes de compilar, deve criar o ficheiro de credenciais:

1. Duplique o ficheiro `include/secrets.example.h`.
2. Renomeie a cópia para `include/secrets.h`.
3. Preencha as credenciais da rede local e do broker Mosquitto da AWS EC2:

```cpp
#pragma once
#define WIFI_SSID        "Sua_Rede_WiFi"
#define WIFI_PASSWORD    "Sua_Senha_WiFi"

#define MQTT_BROKER_IP   "IP_DA_AWS"
#define MQTT_BROKER_PORT 1883
#define MQTT_CLIENT_ID   "unbot-esp32-lock-01"
#define MQTT_USERNAME    "gateway"
#define MQTT_PASSWORD    "Senha_do_Broker"
```

## 📡 Contrato de Comunicação (MQTT)

Para o novo fluxo de MFA Ótico, o hardware agora subscreve a dois tópicos distintos: um para a interface e outro para a ação física.

### 1. Preparação (Exibição do QR Code)
* **Tópico:** `robot/commands/display_qr`
* **Descrição:** Chamado pelo backend assim que o robô chega ao ponto de entrega. O ESP32 desenha o código no ecrã.
* **Formato Esperado:**
```json
{
  "order_id": "pedido_001",
  "otp": "7429",
  "issued_at": 1778630300
}
```

### 2. Execução (Abertura da Tranca)
* **Tópico:** `robot/commands/unlock`
* **Descrição:** Chamado pelo backend apenas após o utilizador escanear o ecrã do robô com a app e a validação do OTP ser bem-sucedida.
* **Formato Esperado:**
```json
{
  "order_id": "pedido_001",
  "action": "open",
  "issued_at": 1778630345
}
```

### 3. Publicação de Telemetria (Publish)
* **Tópico:** `robot/status/heartbeat`
* **Formato:** JSON contendo `source`, `status`, `uptime_s`, `rssi_dbm` e `free_heap_bytes`.
* Inclui a configuração de *Last Will and Testament (LWT)*, avisando a nuvem imediatamente caso a placa perca energia.

## 💻 Como Compilar e Gravar
1. Abra a pasta do projeto no VS Code com a extensão **PlatformIO** instalada.
2. Certifique-se de que o `secrets.h` foi corretamente preenchido.
3. Ligue o ESP32 via USB.
4. Clique no ícone de `✔` (Build) ou `→` (Upload) na barra azul inferior do VS Code.