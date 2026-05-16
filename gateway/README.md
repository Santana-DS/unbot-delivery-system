# UnBot Gateway V2.1 (Security & Cloud Ready)

Backend em Go e Gateway MQTT para o sistema de entregas autônomas UnBot Delivery.

## 🌩️ Arquitetura e Nuvem (MFA Óptico e Resiliência)
Na versão 2.0, migramos o Broker Mosquitto para a **Nuvem AWS (EC2)**, eliminando o Ponto Único de Falha (o PC do robô). Agora, na versão **2.1**, o nosso Gateway atua como o cérebro da nova **Autenticação em Duas Etapas por Proximidade Física (MFA Óptico)**.

**Como funciona o novo fluxo:**
1. O Gateway Go gera um OTP único no momento do despacho.
2. Quando o robô notifica que chegou ao destino, o backend publica o comando (`robot/commands/display_qr`) para o hardware (ESP32) desenhar o QR Code dinâmico no ecrã OLED.
3. O cliente escaneia o código via App; o Gateway valida o pedido via `POST /api/validate-code` e, em caso de sucesso, publica o comando de abertura (`robot/commands/unlock`) diretamente para a tranca.

## 📂 Estrutura de Diretórios

```text
gateway/
├── cmd/
│   └── gateway/
│       └── main.go          # Ponto de entrada — injeção de dependências
├── internal/
│   ├── api/
│   │   ├── server.go        # Servidor HTTP e registro de rotas
│   │   ├── validate.go      # Handler para validação de OTP via MFA
│   │   └── dispatch.go      # Handler POST /api/orders/{id}/dispatch
│   ├── config/
│   │   └── config.go        # Carregamento e validação de variáveis de ambiente (.env)
│   ├── mqtt/
│   │   └── client.go        # Wrapper do Paho, auto-reconexão e handlers
│   └── services/
│       ├── otp.go           # Geração e validação de OTP (Thread-safe)
│       ├── order.go         # Orquestração de pedidos (Navigate + OTP Display)
│       ├── otp_test.go      # Testes de concorrência e isolamento
│       └── order_test.go    # Testes de integridade do fluxo de despacho
├── scripts/
│   └── setup_mosquitto.sh   # Script IaC — instalação automatizada do Broker Mosquitto
├── .env.example             # Template das variáveis de ambiente
├── go.mod                   # Gerenciador de pacotes Go
└── Makefile                 # Automação de comandos locais
```

## 🚀 Guia Rápido (Ambiente de Desenvolvimento Local)
*Nota: Atualmente o servidor Go corre localmente e comunica com a nuvem AWS.*

```bash
# 1. Instale as dependências
go mod tidy

# 2. Crie e preencha o arquivo de ambiente
cp .env.example .env
# Edite o .env com as credenciais da nuvem AWS (Nunca comite este arquivo!)

# 3. Rode o Gateway
make run
```

## 🌐 Contratos da API (Gateway AWS)

A API expõe rotas HTTP para o aplicativo Flutter e orquestra comandos via MQTT para o hardware.

* **`POST /api/orders/{id}/dispatch`**
    * **Função:** Orquestra a entrega. Gera criptograficamente o OTP de 4 dígitos e publica o comando de navegação para o ROS 2. Prepara o payload para o ecrã do ESP32.
* **`POST /api/validate-code`**
    * **Função:** Valida o código lido pela câmara do App. Utiliza `sync.Mutex` para prevenir ataques de *double-spending* (condições de corrida) e publica o comando de abertura (`robot/commands/unlock`) para a trava física.

## 📡 Como Testar a Comunicação MQTT (Para a Equipa)
Utilize o programa **MQTT Explorer** com os dados abaixo para auditar os tópicos:

* **Host:** `3.22.171.3`
* **Port:** `1883`
* **Username:** `gateway`
* **Password:** *(Solicite ao Tech Lead)*

Para simular o disparo de um cliente abrindo a trava, use o PowerShell (com o gateway rodando localmente):

```powershell
Invoke-RestMethod -Uri http://localhost:8080/api/validate-code -Method POST -ContentType "application/json" -Body '{"code":"1234","order_id":"order_mock_001"}'
```

## 📊 Estado Atual (Kanban de Sprints)

| Sprint | Foco | Status |
| :--- | :--- | :--- |
| **V2.0** | Migração Go, Nuvem MQTT, Validação e Dispatch HTTP | ✅ Concluído |
| **V2.1** | Integração Flutter (Scanner QR), MFA Físico, UI State e Firmware ESP32 | ✅ Concluído |
| **V2.2** | *Deploy* do Servidor Go para a Nuvem AWS (Ambiente de Produção) | 🟡 Próximo Passo |
| **V3.0** | WebRTC Raspberry Pi, Joystick Mobile e Transmissão de Vídeo | ⏳ Na Fila |