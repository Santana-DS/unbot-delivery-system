# UnBot Gateway V2.0

Backend em Go e Gateway MQTT para o sistema de entregas autônomas UnBot Delivery V2.0.

## 🌩️ Arquitetura e Nuvem (Por que mudamos?)
Na versão 1.0, o nosso Broker MQTT (o coração das mensagens) rodava dentro do notebook embarcado no robô. Isso criava um **Ponto Único de Falha**: se o robô ficasse sem bateria, o aplicativo do cliente parava de funcionar e a trava não abria.

Na versão 2.0, migramos o Broker Mosquitto e este Gateway para a **Nuvem AWS**. 
**Vantagens:**
1. **Fail-safe (Tolerância a falhas):** A trava da marmita (ESP32) é um sistema independente. Mesmo que o PC de navegação do robô trave, o ESP32 continua conectado à AWS e o cliente consegue retirar o pedido.
2. **Segurança M2M:** Implementamos autenticação Machine-to-Machine com senhas fechadas, impedindo acessos não autorizados à rede do campus.

## 📂 Estrutura de Diretórios

```
unbot-gateway/
├── cmd/
│   └── gateway/
│       └── main.go          # Ponto de entrada — apenas inicialização, sem regras de negócio
├── internal/
│   ├── config/
│   │   └── config.go        # Carregamento e validação de variáveis de ambiente (.env)
│   ├── mqtt/
│   │   └── client.go        # Wrapper do Paho, constantes de tópicos e stubs de handlers
│   └── api/
│       └── server.go        # Servidor HTTP, rotas de /health e validação de OTP
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

## 📡 Como Testar a Nuvem (Para a Equipe)
Você não precisa subir o servidor Go para ver se a nuvem está viva. Utilize o programa **MQTT Explorer** com os dados abaixo (O app salva esses dados após o primeiro acesso):

*   **Host:** `3.22.171.3`
*   **Port:** `1883`
*   **Username:** `gateway`
*   **Password:** *(Solicite ao Tech Lead)*

Com o Gateway Go rodando localmente, você pode publicar um pulso de vida simulado a partir de qualquer terminal com `mosquitto-clients`:

```bash
mosquitto_pub \
  -h 3.22.171.3 -p 1883 \
  -u gateway -P <gateway-password> \
  -t robot/status/heartbeat \
  -m '{"source":"mock","status":"online"}'
```

O terminal do seu Gateway local deverá imprimir:
```json
{"level":"INFO","msg":"heartbeat received","topic":"robot/status/heartbeat","payload":"{...}"}
```

## 🎯 Próximos Tickets
- `internal/services/otp.go`  — Lógica de geração e validação de OTP
- `internal/api/dispatch.go`  — Handler para POST `/api/orders/{id}/dispatch`
- `internal/api/validate.go`  — Handler para POST `/api/validate-code`
- `internal/mqtt/publisher.go`— Helpers tipados para publicação (navigate, unlock)