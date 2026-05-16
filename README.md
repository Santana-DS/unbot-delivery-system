# UnBot Delivery — ESP32 Firmware (Módulo de Acionamento e Interface)

Este repositório contém o firmware em C++ (Framework Arduino via PlatformIO) responsável por gerenciar a trava física (atuador) e a interface visual do UnBot. Ele atua como um nó IoT edge, recebendo comandos diretos da nuvem AWS via MQTT.

## 🚀 Arquitetura e Funcionalidades

* **Conexão Resiliente:** Máquina de estados não-bloqueante (`MqttManager`) que gerencia a conexão Wi-Fi e MQTT simultaneamente. Possui reconexão automática e *backoff* exponencial.
* **MFA Óptico (Display Dinâmico):** Geração de QR Code em tempo real no display do robô, refletindo o OTP dinâmico do pedido atual para validação via app do cliente.
* **Validação de Segurança:** Processamento de JSON via `ArduinoJson` (v7) com leitura estrita de memória.
* **Proteção contra Replay Attacks:** Verifica o campo `issued_at` (Unix Timestamp) para descartar comandos defasados retidos pelo broker.
* **Telemetria:** Publicação automática de *Heartbeat* (pulso de vida) a cada 30 segundos, informando status, uptime e uso de RAM.

## 🔌 Setup de Hardware

O processamento é feito de forma *non-blocking* para garantir que a atualização da tela não congele a recepção de pacotes da rede.

* **Atuador/Trava:** `GPIO 2` (Pino `2`). Ficará em estado `HIGH` por exatamente **5000 ms** (5 segundos) após o comando de abertura validado.
* **Display (I2C/SPI):** *(Pinos a definir conforme o módulo escolhido pela equipe de hardware)*. Responsável por renderizar o QR Code gerado localmente no microcontrolador.

## ⚙️ Dependências (PlatformIO)

As dependências são gerenciadas automaticamente pelo `platformio.ini`:

* `knolleary/PubSubClient @ ^2.8.0`
* `bblanchon/ArduinoJson @ ^7.4.3`
* `ricmoo/QRCode @ ^0.0.1` *(Nova dependência para geração do QR Code matemático)*
* *(Dependência do driver do display pendente)*

## 🔐 Configuração Inicial

As credenciais de Wi-Fi e AWS **não estão no controle de versão** por segurança.
Antes de compilar, você deve criar o arquivo de credenciais:

1. Duplique o arquivo `include/secrets.example.h`.
2. Renomeie a cópia para `include/secrets.h`.
3. Preencha as credenciais da rede e do broker Mosquitto:

```cpp
#pragma once
#define WIFI_SSID        "Sua_Rede_WiFi"
#define WIFI_PASSWORD    "Sua_Senha_WiFi"

#define MQTT_BROKER_IP   "IP_DA_AWS_EC2"
#define MQTT_BROKER_PORT 1883
#define MQTT_CLIENT_ID   "unbot-esp32-lock-01"
#define MQTT_USERNAME    "gateway"
#define MQTT_PASSWORD    "Senha_do_Broker"

```

## 📡 Contrato de Comunicação (MQTT)

A lógica agora exige dois eventos de recebimento distintos do backend:

### 1. Atualizar Display (Novo)

Quando o robô chega ao destino, o backend envia a senha para ser gerada como QR Code.

* **Tópico:** `robot/commands/display`
* **Formato Esperado:**

```json
{
  "order_id": "pedido_001",
  "code": "8134",
  "action": "show_qr"
}

```

### 2. Abertura do Compartimento (Unlock)

Após o cliente escanear o código com sucesso e o Go validar a requisição.

* **Tópico:** `robot/commands/unlock`
* **Formato Esperado:**

```json
{
  "order_id": "pedido_001",
  "issued_at": 1778630301
}

```

### Publicação (Publish)

* **Tópico:** `robot/status/heartbeat`
* **Formato:** JSON contendo `source`, `status`, `uptime_s`, `rssi_dbm` e `free_heap_bytes`.
