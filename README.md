# 🤖 UnBot Delivery: Sistema de Logística Autônoma UnB

<img src="./docs/banner.png" width="50%">

O **UnBot Delivery** é uma solução avançada de logística *last-mile* desenvolvida para o campus da Universidade de Brasília (UnB). O sistema integra tecnologias móveis, backend escalável e hardware ciber-físico para permitir entregas autônomas e seguras.

---

## 🏗️ Arquitetura do Sistema

O projeto opera em uma arquitetura distribuída e assíncrona, composta por quatro pilares fundamentais:

| Entidade | Tecnologia | Função |
| :--- | :--- | :--- |
| **App Mobile** | Flutter | Interface do usuário e gerenciamento de pedidos via `ValueNotifier`. |
| **Gateway** | FastAPI (Python) | Orquestrador lógico, segurança OTP e ponte de dados. |
| **Broker** | Mosquitto MQTT | Barramento de mensageria de baixa latência para comunicação com hardware. |
| **Robô** | ESP32 / ROS 2 | Atuador físico, telemetria e interface ciber-física. |

```mermaid
graph TD
    subgraph App ["📱 1. Interface Mobile (App Flutter)"]
        UI["Navegação e Rastreamento"]
        Auth["Geração de Código OTP"]
    end

    subgraph Backend ["🧠 2. Gateway / Lógica (FastAPI / Python)"]
        API["Servidor REST & WebSockets"]
        Broker["Broker MQTT"]
        API --- Broker
    end

    subgraph Computacional ["🗺️ 3. Alto Nível (ROS 2 / Raspberry Pi 3B)"]
        Nav["Nav2 & SLAM (Pacotes C++)"]
        EKF["robot_localization (C++)"]
        Tele["Nó de Telemetria (Python)"]
        Nav --- EKF
        EKF --- Tele
    end

    subgraph Hardware ["⚙️ 4. Baixo Nível (ESP32 / Mecânica)"]
        Micro["ESP32 com Micro-ROS"]
        Atuadores["Motores & Trava Solenoide"]
        Sensores["Odometria & Bateria"]
        Micro --- Atuadores
        Micro --- Sensores
    end

    UI <-->|"HTTP / WebSockets"| API
    Auth -->|"Validação de Código"| API
    Broker <-->|"MQTT"| Tele
    Nav <-->|"Micro-ROS / UART"| Micro

```

---

## 🚀 Guia de Setup e Execução

### 📋 Pré-requisitos
* **Flutter SDK (3.27+)**
* **Python 3.10+**
* **Mosquitto MQTT Broker**
* **VS Code** (Extensões: Flutter, Dart, Python)

### 🛠️ Passo a Passo para Desenvolvimento

1.  **Inicialize o Broker MQTT:**
    ```bash
    net start mosquitto
    ```
2.  **Inicie o Backend Gateway:**
    Navegue até `/backend_gateway` e execute:
    ```bash
    pip install fastapi uvicorn paho-mqtt python-dotenv
    uvicorn main:app --host 0.0.0.0 --port 8000 --reload
    ```
3.  **Configure o Túnel (Dev Tunnels):**
    No VS Code, encaminhe a porta `8000`, mude para **Public** e cole o link gerado no `api_service.dart`.
4.  **Simule o Robô (Heartbeat):**
    Para habilitar o despacho no App, envie o sinal de vida do robô via PowerShell:
    ```bash
     & 'C:\Program Files\mosquitto\mosquitto_pub.exe' -t "robot/status/heartbeat" -m "{\`"status\`": \`"online\`"}"
    ```
5.  **Rode o App:**
    ```bash
    flutter pub get
    flutter run
    ```

---

## 🔐 Lógica Técnica e Segurança

### Gerenciamento de Estado
Utilizamos o padrão **Observer** com `ValueListenableBuilder` para garantir que a interface seja reativa a múltiplos pedidos simultâneos sem perda de performance.

### Protocolo Peek-and-Consume (OTP)
A segurança da retirada baseia-se em um segredo criptográfico gerado via `secrets` (Python). O código só é validado após o Broker confirmar a entrega da mensagem MQTT ao hardware, garantindo a transacionalidade da entrega física.

---

## 📦 Distribuição (Build do APK)

Para gerar o executável de produção para Android, siga o procedimento de **Clean Build** para evitar corrupção de artefatos:

```bash
# 1. Limpeza profunda de cache
flutter clean

# 2. Reconstrução de dependências
flutter pub get

# 3. Compilação Ahead-of-Time (AOT)
flutter build apk --release
```

**⚠️ Importante:** O artefato final será gerado em `build/app/outputs/flutter-apk/app-release.apk`. Certifique-se de que o `AndroidManifest.xml` contenha as permissões de `INTERNET` e `usesCleartextTraffic="true"` para garantir a conectividade em modo Release.

---

## 📊 Estado Atual (Kanban)

![Quadro Kanban](./docs/kanban.png)
*Visão geral do progresso técnico e backlog do projeto.*


---

## 🎓 Créditos
Projeto desenvolvido como parte do **PIT (Projeto Integrador)** da **Faculdade de Tecnologia (FT)** - Engenharia Mecatrônica - Universidade de Brasília (UnB).

