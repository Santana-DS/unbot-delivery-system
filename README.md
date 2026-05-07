# 🤖 UnBot Delivery: Sistema de Logística Autônoma UnB

<img src="./docs/banner.png" width="50%">

O **UnBot Delivery** é uma solução avançada de logística *last-mile* desenvolvida para o campus da Universidade de Brasília (UnB). O sistema integra tecnologias móveis, backend em nuvem e hardware ciber-físico distribuído, permitindo navegação autônoma com suporte a teleoperação de contingência em tempo real.

---

## 🏗️ Arquitetura do Sistema (V2.0 - Teleoperação e Nuvem)

O projeto evoluiu para uma arquitetura distribuída e tolerante a falhas. Separamos a camada de navegação pesada da camada de atuação crítica, utilizando cinco pilares fundamentais:

| Entidade | Tecnologia | Função |
| :--- | :--- | :--- |
| **App Mobile** | Flutter | UI de pedidos, rastreamento reativo e "Cockpit" de teleoperação (Joystick e Vídeo). Suporte a desbloqueio híbrido (QR/OTP). |
| **Gateway (Nuvem)** | Go (Golang) / Pion | Servidor de alta performance para validação transacional e sinalização WebRTC. |
| **Broker (Nuvem)** | Mosquitto MQTT | Barramento seguro de baixa latência (M2M) para comandos físicos. |
| **Cérebro (Robô)** | Notebook + ROS 2 | Processamento de Visão Computacional (ORB-SLAM3) e Navegação Autônoma. |
| **Reflexos (Robô)**| RPi 3B + ESP32 | RPi para streaming de vídeo (WebRTC); ESP32 isolado para atuação da trava (MQTT). |

### 🗺️ Topologia de Rede e Dados

```mermaid
graph TD
    subgraph Cloud ["☁️ 1. Infraestrutura em Nuvem (AWS/Oracle)"]
        API["Backend Gateway & Sinalização WebRTC (Go)"]
        Broker["Broker MQTT (Mosquitto)"]
    end

    subgraph App ["📱 2. Interface Mobile (Flutter)"]
        UI["App: Pedidos e Rastreamento"]
        Teleop["App: Cockpit de Pilotagem (Vídeo + Joystick)"]
    end

    subgraph Computacional ["🧠 3. Alto Nível (Robô - Processamento)"]
        Note["Notebook (ROS 2 / ORB-SLAM3)"]
        Pi["Raspberry Pi 3B (Nó de Teleoperação)"]
        CamUSB["Câmera USB (Visão SLAM)"] --> Note
        CamPi["Câmera CSI (Vídeo Otimizado)"] --> Pi
    end

    subgraph Hardware ["⚙️ 4. Baixo Nível (Atuadores Isolados)"]
        ESP["ESP32 (Módulo Wi-Fi Independente)"]
        Motor["Controladora de Motores (Ponte H)"]
        Trava["Trava Solenoide / LED Mock"]
        
        ESP -->|"Relé / GPIO"| Trava
        Pi -->|"Sinal Serial / PWM"| Motor
        Note <-->|"cmd_vel (Velocidade Autônoma)"| Motor
    end

    %% Conexões de Rede
    UI <-->|"HTTP (Transações OTP/QR)"| API
    Teleop <-->|"WebRTC P2P (Vídeo H.264 e Joystick)"| Pi
    API -->|"Comandos"| Broker
    Broker -->|"Tópico: robot/commands/unlock"| ESP
    Pi -->|"Telemetria (Bateria/GPS)"| Broker
```

---

## 🚀 Guia de Setup e Integração

### 📋 Pré-requisitos
* **Flutter SDK (3.27+)**
* **Go (Golang 1.22+)** para o Backend V2.
* **Ambiente Nuvem:** Instância EC2/Oracle com portas 1883 (MQTT) e 8080 (API) expostas.
* **VS Code / PlatformIO** para o firmware do ESP32 em C++.

### 🛠️ Passos de Execução (Fase de Transição)

1.  **Subir a Infraestrutura na Nuvem:**
    O Mosquitto e o Gateway em Go rodam no servidor remoto (AWS), garantindo que o hardware móvel do robô não atue como ponto único de falha.
2.  **Firmware ESP32 (Trava de Segurança):**
    O ESP32 conecta-se ao Wi-Fi/4G e se inscreve no tópico seguro do Mosquitto na nuvem. *(Nota de Prototipagem: O acionamento da trava solenoide está sendo validado fisicamente através de um LED indicador acoplado aos GPIOs do ESP32).*
3.  **Configuração do WebRTC (Raspberry Pi):**
    Conectar a Pi Camera Module (CSI). Iniciar o nó em Python/Go no Raspberry que aguarda a sinalização P2P para iniciar a transmissão de vídeo acelerada por hardware (H.264).
4.  **Execução do App Mobile:**
```bash
flutter clean
flutter pub get
flutter run
```

---

## 🔐 Lógica Técnica e Segurança Transacional

### Isolamento de Falhas (Fail-Safe)
A arquitetura foi desenhada para garantir a integridade da entrega. O comando de abertura da trava viaja via MQTT da nuvem diretamente para o ESP32. Se o sistema de navegação (Notebook/ROS 2) falhar ou o robô colidir, o usuário ainda poderá autorizar o destravamento do compartimento físico.

### Interface Híbrida e Agnosticismo de Backend
O aplicativo suporta desbloqueio via **Leitura de QR Code** ou **Digitação Manual (OTP)**. O Gateway Go é agnóstico à interface: ele recebe o dado bruto via HTTP POST, blindando a regra de negócio e mantendo o servidor focado exclusivamente na validação transacional.

### Protocolo Peek-and-Consume (Thread-Safe)
A senha criptográfica só é marcada como "usada" na memória (protegida por Mutex contra condições de corrida) e no banco de dados do Backend após a validação. Falhas de hardware (Broker inacessível) resultam em um `502 Bad Gateway`, impedindo que o aplicativo exiba mensagens falsos-positivos ao usuário.

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

## 📊 Estado Atual (Kanban de Sprints)

![Quadro Kanban](./docs/kanban.png)
*Visão geral do progresso técnico e backlog do projeto.*

| Sprint | Foco | Status |
| :--- | :--- | :--- |
| **V1.0** | App Base, Gateway Local, Multi-Pedido | ✅ Concluído |
| **V2.0 - Sprint 1** | Migração Go, Nuvem MQTT, Validação OTP HTTP | ✅ Concluído |
| **V2.0 - Sprint 2** | Integração Flutter (QR/OTP), UI State e ESP32 Firmware | 🟡 Em Andamento |
| **V3.0** | WebRTC Raspberry Pi, Joystick Mobile e Vídeo | ⏳ Na Fila |

---

## 🎓 Créditos e Equipe
Projeto desenvolvido como parte do **Projeto Integrador de Tecnologias (PIT)** da **Faculdade de Tecnologia (FT)** - Engenharia Mecatrônica - Universidade de Brasília (UnB). 

*Equipe distribuída entre as disciplinas de:*
* Interface Mobile & Backend
* Visão Computacional & Navegação Autônoma
* Sistemas Embarcados & Eletrônica