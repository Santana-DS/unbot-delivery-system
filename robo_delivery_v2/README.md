# 🤖 RoboDelivery App - Interface Mobile

Este diretório contém o código-fonte da interface mobile para o sistema de entrega autônoma de refeições (UGV - Unmanned Ground Vehicle). O aplicativo é desenvolvido em **Flutter** e atua como a central de comando para clientes e o painel de telemetria para os estabelecimentos.

## 📂 Arquitetura do Projeto

O projeto segue uma estrutura modular para facilitar a manutenção e a futura integração com o hardware via ROS/Python.

- **lib/**
    - **main.dart**: Inicialização do app e gerenciamento dinâmico de temas.
    - **theme/app_theme.dart**: Definição do Design System baseado em Material 3.
    - **models/models.dart**: Estruturas de dados para Pedidos, Restaurantes e Produtos.
    - **widgets/widgets.dart**: Componentes de UI customizados e renderizações via CustomPainter (como o mapa e o ícone dinâmico do robô).
    - **screens/**:
        - **splash_screen.dart**: Tela de boas-vindas com animações de branding.
        - **login_screen.dart**: Portal de acesso com seleção de perfil.
        - **client/**: Experiência do usuário final (Home, Rastreamento e Código de Retirada).
        - **restaurant/**: Gestão logística (Dashboard de pedidos e telemetria do robô).

## 🛠️ Tecnologias e Padrões
* **Flutter & Material 3**: Interface moderna seguindo as últimas diretrizes de design do Google.
* **Canvas API (CustomPainter)**: Utilizada no arquivo `widgets.dart` para desenhar elementos gráficos complexos sem depender de imagens, otimizando o consumo de recursos.
* **Reactive Theme**: Gerenciamento de tema (Claro/Escuro) utilizando `ValueNotifier` para mudanças em tempo real.

## 🗺️ Roadmap de Desenvolvimento

### 1. Integração com Backend (Próximo Passo)
Substituir as estruturas de dados estáticas por uma comunicação real via API. O backend será desenvolvido em **Python (FastAPI)** para garantir compatibilidade nativa com os nós do ROS que controlam o robô.

### 2. Controle de Hardware e Segurança
Implementar o gatilho de comunicação no módulo de retirada. Ao validar o código no aplicativo, o sistema enviará um sinal criptografado para o servidor, que por sua vez acionará a trava eletromecânica do compartimento do robô.

### 3. Monitoramento de Telemetria
Desenvolver a ponte de dados entre o ROS e o App para exibir, em tempo real, o status crítico do robô:
* Nível de bateria.
* Localização precisa via GPS/Odometria.
* Status dos sensores de navegação.

## 🛠️ Arquitetura de Integração e Controle

Para garantir a viabilidade técnica no hardware alvo (Raspberry Pi 3B), adotamos uma arquitetura híbrida de alto desempenho:

* **Camada de Controle e Percepção (C++):** Processamento de Visual SLAM, Nav2 e EKF (robot_localization) via nós nativos em C++, garantindo baixa latência e otimização de CPU/RAM.
* **Camada de Aplicação e Bridge (Python/FastAPI):** Servidor de telemetria e lógica de negócio, atuando como interface entre o App Flutter e o ecossistema ROS 2.
* **Protocolo de Comunicação:** Utilização de MQTT para troca de mensagens leve e assíncrona entre o UGV e o servidor central.
