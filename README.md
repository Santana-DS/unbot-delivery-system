Aqui tens o conteúdo do `README.md` atualizado, substituindo os blocos de código (crases) por ````` para que possas copiar sem problemas de formatação no chat e alterar manualmente depois:

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
│   │   └── validate.go      # Handler POST /api/validate-code (Tradução HTTP -> Service)
│   ├── config/
│   │   └── config.go        # Carregamento e validação de variáveis de ambiente (.env)
│   ├── mqtt/
│   │   └── client.go        # Wrapper do Paho, auto-reconexão e stubs de handlers
│   └── services/
│       ├── otp.go           # Regra de negócio de validação, uso único e interface do Publisher
│       └── otp_test.go      # Testes de concorrência (Race) e isolamento da regra de negócio
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
Você não precisa subir o servidor Go para ver se a nuvem está viva. Utilize o programa **MQTT Explorer** com os dados abaixo:

* **Host:** `3.22.171.3`
* **Port:** `1883`
* **Username:** `gateway`
* **Password:** *(Solicite ao Tech Lead)*

Você pode simular o celular de um cliente liberando a trava disparando este comando no PowerShell (Com o gateway rodando localmente):

```powershell
Invoke-RestMethod -Uri http://localhost:8080/api/validate-code -Method POST -ContentType "application/json" -Body '{"code":"1234","order_id":"order_mock_001"}'
```
Você verá a ordem de abertura aparecer instantaneamente no tópico `robot/commands/unlock` no MQTT Explorer.

## 🎯 Próximos Tickets
- `internal/api/dispatch.go`  — Handler para POST `/api/orders/{id}/dispatch`
- `internal/mqtt/publisher.go`— Helpers tipados para publicação (navigate, status)