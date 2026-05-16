# UnBot Delivery — Frontend (Flutter App)

Aplicativo mobile do cliente para o ecossistema UnBot Delivery. Construído em Flutter, o app é responsável por orquestrar a jornada do utilizador desde o pedido até à Autenticação de Múltiplos Fatores (MFA) física no momento da retirada da marmita.

## 📱 Funcionalidades Principais (v2.1)
* **Gestão de Estado Reativa:** Utilização de `ChangeNotifier` para atualizações de UI em tempo real, sem *rebuilds* desnecessários da árvore de widgets.
* **MFA Óptico (Segurança de Retirada):** Integração com a câmera nativa do dispositivo para ler o QR Code dinâmico gerado no ecrã do robô. O compartimento só abre se o código lido coincidir com o OTP gerado pelo backend em Go.
* **Fallback Manual:** Opção de digitação manual do código caso o utilizador esteja com a câmera danificada.
* **Injeção de Dependências:** Configuração da URL da API via variáveis de compilação, permitindo transição fluida entre ambiente local e produção na AWS.

## 🛠️ Tecnologias e Pacotes Críticos
* **`mobile_scanner: ^5.0.0`**: Biblioteca de última geração (baseada em ML Kit / AVFoundation) para leitura de QR Codes em tela cheia com alta performance e controle de ciclo de vida seguro.
* **`google_fonts`**: Tipografia padronizada (Space Grotesk e DM Sans).

## 🚀 Como Executar o Projeto

Para garantir que o aplicativo consiga comunicar com o servidor em Go (seja na rede local ou na nuvem), é obrigatório injetar a URL base da API no momento da compilação.

### Pelo Terminal:
```bash
flutter pub get
flutter run --dart-define=API_BASE_URL=http://SEU_IP_OU_AWS:8080
```

### Pelo VS Code (Recomendado):
Utilize o ficheiro `.vscode/launch.json` configurado na raiz do projeto. Ele já injeta a variável `API_BASE_URL` no `toolArgs` automaticamente ao premir **F5**.

## 🔐 Permissões Nativas
Para o scanner funcionar corretamente em dispositivos reais, as permissões de hardware já estão configuradas nos manifestos nativos:
* **Android:** `<uses-permission android:name="android.permission.CAMERA" />` em `AndroidManifest.xml`.
* **iOS:** `NSCameraUsageDescription` preenchido no `Info.plist`.

## 📂 Estrutura de Rotas e Telas
O fluxo de retirada foi refatorado para garantir a integridade da entrega:
1. `order_details.dart`: Mostra o status de navegação do robô.
2. `code_screen.dart`: Exibe o timer da entrega e fornece as opções de "Escanear" ou digitação manual.
3. `otp_unlock_screen.dart`: Sobreposição da câmera (overlay) isolada, com validação matemática no método `_onDetect` garantindo que apenas o QR Code do pedido atual seja aceite.