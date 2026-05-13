# UnBot Delivery — ESP32 Firmware (Módulo de Acionamento)

Este repositório contém o firmware em C++ (Framework Arduino via PlatformIO) responsável por gerenciar a trava física (atuador) do UnBot. Ele atua como um nó IoT edge, recebendo comandos diretos da nuvem AWS via MQTT.

## 🚀 Arquitetura e Funcionalidades
* **Conexão Resiliente:** Máquina de estados não-bloqueante (`MqttManager`) que gerencia a conexão Wi-Fi e MQTT simultaneamente. Possui reconexão automática e *backoff* exponencial.
* **Validação de Segurança:** Processamento de JSON via `ArduinoJson` (v7) com leitura estrita de memória.
* **Proteção contra Replay Attacks:** Verifica o campo `issued_at` (Unix Timestamp) para descartar comandos defasados retidos pelo broker.
* **Telemetria:** Publicação automática de *Heartbeat* (pulso de vida) a cada 30 segundos, informando status, uptime e uso de RAM.

## 🔌 Setup de Hardware
O pino de acionamento está configurado para atuar em modo *non-blocking* (sem pausar a execução da rede).
* **Atuador/Trava:** `GPIO 2` (Pino `2`).
* O pino ficará em estado `HIGH` por exatamente **5000 ms** (5 segundos) após receber o payload validado.

## ⚙️ Dependências (PlatformIO)
As dependências são gerenciadas automaticamente pelo `platformio.ini`:
* `knolleary/PubSubClient @ ^2.8.0`
* `bblanchon/ArduinoJson @ ^7.4.3`

## 🔐 Configuração Inicial (Para a Equipe de Hardware)
As credenciais de Wi-Fi e AWS **não estão no controle de versão** por segurança. 
Antes de compilar, você deve criar o arquivo de credenciais:

1. Duplique o arquivo `include/secrets.example.h`.
2. Renomeie a cópia para `include/secrets.h`.
3. Preencha as credenciais da rede e do broker Mosquitto:

```cpp
#pragma once
#define WIFI_SSID        "Sua_Rede_WiFi"
#define WIFI_PASSWORD    "Sua_Senha_WiFi"

#define MQTT_BROKER_IP   "IP_DA_AWS"
#define MQTT_BROKER_PORT 1883
#define MQTT_CLIENT_ID   "unbot-esp32-01"
#define MQTT_USERNAME    "gateway"
#define MQTT_PASSWORD    "Senha_do_Broker"
```

## 📡 Contrato de Comunicação (MQTT)

### Recebimento (Subscribe)
* **Tópico:** `robot/commands/unlock`
* **Formato Esperado:**
```json
{
  "order_id": "pedido_001",
  "code": "8134",
  "issued_at": 1778630301
}
```
*(Nota: O backend em Go transmite o `issued_at` obrigatoriamente como `int64` (Unix Timestamp em segundos) para otimização de CPU/RAM do microcontrolador).*

### Publicação (Publish)
* **Tópico:** `robot/status/heartbeat`
* **Formato:** JSON contendo `source`, `status`, `uptime_s`, `rssi_dbm` e `free_heap_bytes`.
* Inclui a configuração de *Last Will and Testament (LWT)* avisando a nuvem imediatamente caso a placa perca energia.

## 💻 Como Compilar e Gravar
1. Abra a pasta do projeto no VS Code com a extensão **PlatformIO** instalada.
2. Certifique-se de que o `secrets.h` foi criado.
3. Conecte o ESP32 via USB.
4. Clique no ícone de `✔` (Build) ou `→` (Upload) na barra azul inferior do VS Code.