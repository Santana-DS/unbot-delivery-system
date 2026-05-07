# UnBot Gateway V2.0

Backend em Go e Gateway MQTT para o sistema de entregas autônomas UnBot Delivery V2.0.

## 🌩️ Arquitetura e Nuvem (Por que mudamos?)
Na versão 1.0, o nosso Broker MQTT (o coração das mensagens) rodava dentro do notebook embarcado no robô. Isso criava um **Ponto Único de Falha**: se o robô ficasse sem bateria, o aplicativo do cliente parava de funcionar e a trava não abria.

Na versão 2.0, migramos o Broker Mosquitto e este Gateway para a **Nuvem AWS**. 
**Vantagens:**
1. **Fail-safe (Tolerância a falhas):** A trava da marmita (ESP32) é um sistema independente. Mesmo que o PC de navegação do robô trave, o ESP32 continua conectado à AWS e o cliente consegue retirar o pedido.
2. **Segurança M2M:** Implementamos autenticação Machine-to-Machine com senhas fechadas, impedindo acessos não autorizados à rede do campus.

## 📂 Estrutura de Diretórios

```text
unbot-gateway/
├── cmd/
│   └── gateway/
│       └── main.go          # Ponto de entrada — fiação de injeção de dependências
├── internal/
│   ├── api/
│   │   ├── server.go        # Servidor HTTP e registro de rotas
│   │   ├── validate.go      # Handler para validação de OTP
│   │   └── dispatch.go      # Handler POST /api/orders/{id}/dispatch
│   ├── config/
│   │   └── config.go        # Carregamento e validação de variáveis de ambiente (.env)
│   ├── mqtt/
│   │   └── client.go        # Wrapper do Paho, auto-reconexão e stubs de handlers
│   └── services/
│       ├── otp.go           # Geração e validação de OTP (Thread-safe)
│       ├── order.go         # Orquestração de pedidos (Navigate + OTP)
│       ├── otp_test.go      # Testes de concorrência e isolamento
│       └── order_test.go    # Testes de integridade do fluxo de despacho
├── scripts/
│   └── setup_mosquitto.sh   # Script IaC — instalação automatizada do Broker Mosquitto
├── .env.example             # Template das variáveis de ambiente
├── go.mod                   # Gerenciador de pacotes Go
└── Makefile                 # Automação de comandos locais
```
## 🚀 Guia Rápido (Local)

```bash
# 1. Instale as dependências
go mod tidy

# 2. Crie e preencha o arquivo de ambiente
cp .env.example .env
# Edite o .env com as credenciais da nuvem (Nunca comite este arquivo!)

# 3. Rode o Gateway
make run
```
## 🌐 Contratos da API (Gateway AWS)

O Backend opera com uma arquitetura agnóstica de interface, expondo rotas HTTP para o aplicativo e orquestrando comandos via MQTT para o hardware.

* **`POST /api/orders/{id}/dispatch`**
    * **Função:** Orquestra a entrega. Gera criptograficamente um OTP de 4 dígitos de uso único e publica o comando de navegação (`robot/commands/navigate`) via MQTT para o sistema ROS 2.
    * **Fallback:** Caso o robô esteja em uma área sem cobertura (Broker inacessível), a API degrada graciosamente para `GatewayModeOTPOnly`, garantindo que o usuário ainda receba o código para retirada manual.
* **`POST /api/validate-code`**
    * **Função:** Valida o OTP recebido do Flutter. Utiliza `sync.Mutex` para prevenir condições de corrida (double-spending) e publica o comando de abertura (`robot/commands/unlock`) diretamente para o ESP32.

## 📡 Como Testar a Nuvem (Para a Equipe)
Você não precisa subir o servidor Go para ver se a nuvem está viva. Utilize o programa **MQTT Explorer** com os dados abaixo:

* **Host:** `3.22.171.3`
* **Port:** `1883`
* **Username:** `gateway`
* **Password:** *(Solicite ao Tech Lead)*

Você pode simular o celular de um cliente liberando a trava disparando este comando no PowerShell (Com o gateway rodando localmente):

```powershell
Invoke-RestMethod -Uri http://localhost:8080/api/validate-code -Method POST -ContentType "application/json" -Body '{"code":"1234","order_id":"order_mock_001"}'
```
## 📊 Estado Atual (Kanban de Sprints)

| Sprint | Foco | Status |
| :--- | :--- | :--- |
| **V1.0** | App Base, Gateway Local, Multi-Pedido | ✅ Concluído |
| **V2.0 - Sprint 1** | Migração Go, Nuvem MQTT, Validação e Dispatch HTTP | ✅ Concluído |
| **V2.0 - Sprint 2** | Integração Flutter (QR/OTP), UI State e ESP32 Firmware | 🟡 Em Andamento |
| **V3.0** | WebRTC Raspberry Pi, Joystick Mobile e Vídeo | ⏳ Na Fila |
```