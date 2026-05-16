# 🤖 UnBot Delivery: Sistema de Logística Autônoma UnB

<img src="./docs/banner.png" width="50%">

O **UnBot Delivery** é uma solução avançada de logística *last-mile* autônoma desenvolvida para o campus da Universidade de Brasília (UnB). 

Este repositório (Monorepo) contém a infraestrutura de software ponta-a-ponta: o aplicativo de pedidos (Flutter), o cérebro transacional e roteamento (Gateway Go), a comunicação via nuvem (MQTT) e o firmware de segurança física da tranca (ESP32 em C++).

---

## 📚 Documentação Arquitetural (Memória do Projeto)

Para manter este repositório escalável e facilitar a integração de novos membros (e IAs), toda a complexidade técnica foi isolada na pasta `docs/`. **Leitura obrigatória antes de codar:**

* 🗺️ **[ARCHITECTURE.md](./docs/ARCHITECTURE.md):** Visão geral do sistema, topologia de rede, responsabilidades dos nós e diagrama estrutural.
* 📜 **[PROTOCOL.md](./docs/PROTOCOL.md):** Contratos de API REST, payloads JSON e mapeamento completo dos tópicos MQTT.
* 🔄 **[STATE_FLOW.md](./docs/STATE_FLOW.md):** Máquinas de estado, fluxo do MFA Óptico (Renderização Sob Demanda) e tratamento de modo degradado.
* 📏 **[CONVENTIONS.md](./docs/CONVENTIONS.md):** Nossas regras de ouro de engenharia (ex: proibição de Heap no ESP32, uso de ValueNotifier, Injeção de Dependência no Go).

---

## 🛠️ Stack Tecnológica

| Camada | Tecnologia | Função Principal |
| :--- | :--- | :--- |
| **Frontend Mobile** | Flutter (Dart) | App do cliente (Pedidos, Scanner Óptico) e interface de teleoperação. |
| **Backend Gateway** | Go (Golang) | API REST de alta concorrência e orquestração de entregas. |
| **Mensageria** | Mosquitto MQTT | Barramento seguro M2M hospedado na nuvem (AWS EC2). |
| **Firmware (Tranca)** | C++ / PlatformIO | ESP32 com Display OLED (SSD1306) para o MFA Óptico e controle do solenoide. |
| **Navegação (Core)** | ROS 2 / Raspberry Pi | Nó computacional embarcado no robô (fora deste monorepo de backend/app). |

---

## 📂 Estrutura do Monorepo

```text
unbot-delivery-system/
├── mobile/          # Aplicativo Flutter (UI e lógica de cliente)
├── gateway/         # Servidor Go (API REST e Publicador MQTT)
├── hardware/
│   └── esp32-lock/  # Firmware C++ da tranca e display (PlatformIO)
└── docs/            # Diagramas, contratos e decisões arquiteturais
```

---

## 🚀 Como Rodar o Projeto (Ambiente Local)

### 1. Backend (Go)
Certifique-se de preencher o `.env` baseado no `.env.example` na pasta `gateway`.
```bash
cd gateway
go run cmd/gateway/main.go
```

### 2. Firmware (ESP32 / Simulador Wokwi)
Abra a pasta `hardware/esp32-lock` no VS Code com a extensão PlatformIO.
```bash
# Compilar o código
pio run -e esp32dev

# Subir para a placa física
pio run -e esp32dev -t upload
```
*(Para simulação, utilize a aba Wokwi apontando para o firmware.elf gerado).*

### 3. Frontend (Flutter)
```bash
cd mobile
flutter pub get
flutter run
```

---

## 🎓 Créditos
Desenvolvido como parte do **Projeto Integrador de Tecnologias (PIT)** da Faculdade de Tecnologia (FT) - Engenharia Mecatrônica - Universidade de Brasília (UnB).