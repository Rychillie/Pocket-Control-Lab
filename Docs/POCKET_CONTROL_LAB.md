# Pocket Control Lab

## Objetivo

`PocketControlLab` é um laboratório local para responder experimentalmente se
os controles UVC anunciados pela DJI Osmo Pocket 4 em Webcam Mode funcionam no
macOS e, em caso positivo, se o efeito observado é movimento físico, PTZ/crop
digital, aceitação sem efeito, ou erro. Ele não é um produto de captura de
vídeo e não usa rede.

O app separa o que foi **detectado ao vivo** daquilo que é apenas **conhecido
de um descriptor observado anteriormente**. Nenhuma conclusão sobre movimento
do gimbal é inferida a partir de `SET_CUR`: cada operação pede confirmação
visual humana.

## Arquitetura

| Área | Local | Responsabilidade |
| --- | --- | --- |
| App / ciclo de vida | `PocketControlLab/App` | retém o único `DeviceSession` e encaminha launch, sleep, wake e terminação |
| Sessão | `PocketControlLab/App` | coordena descoberta, permissão, preview, inspeção, logs, snapshots e trava de escrita |
| Modelos | `PocketControlLab/Models` | dispositivo, formatos, ranges UVC, snapshots, diffs e apresentação tipada da conexão |
| Preview | `PocketControlLab/Camera` | `AVCaptureDevice`, `AVCaptureSession` e `AVCaptureVideoPreviewLayer` em SwiftUI |
| USB | `PocketControlLab/USB` | leitura do IORegistry, ponte UVC estritamente validada, controles padrão e XU |
| Investigação | `PocketControlLab/Investigation` | log local e snapshots/diff |
| UI | `PocketControlLab/UI` | views que solicitam intenções semânticas, sem possuir monitor, preview ou transporte |

O `DeviceSession` é `@MainActor`, observável e com escopo do app; todas as
scenes recebem a mesma sessão. O monitor USB faz polling leve de propriedades
já publicadas pelo IORegistry a cada 1,5 s. Ele não abre nem reivindica
interfaces USB. Isso permite atualizar conexão/desconexão sem competir com a
arquitetura de câmera do macOS.

## Ciclo da sessão

| Intenção | Tipo | Efeito permitido |
| --- | --- | --- |
| `startPassiveDiscovery()` | passiva | inicia ou preserva somente o monitor IORegistry; não solicita TCC, não inicia preview e não faz I/O UVC |
| `stopPassiveDiscovery()` | segurança | executa o teardown seguro completo, inclusive parar o preview quando aplicável |
| `requestCameraPermission()` | ação do operador | consulta/solicita somente o acesso de câmera do macOS |
| `requestPreviewStart()` | ação do operador | para uma Pocket 4 confirmada, solicita permissão se necessária e só então inicia preview local |
| `stopPreview()` | ação do operador/segurança | encerra somente o preview ativo, sem habilitar writes |
| `refreshReadOnlyInspection()` | ação do operador, somente leitura | executa apenas GETs validados para a conexão atual |

A descoberta passiva começa uma vez no launch e permanece independente da
permissão de câmera. Ela nunca inicia outro `AVCaptureSession`, faz inspeção
UVC ou envia `SET_CUR`. A negação de permissão deixa a descoberta ativa e o
preview parado. Nenhuma ação de ciclo de vida habilita writes ou agenda
movimento.

Em wake, o app reinicia somente `startPassiveDiscovery()`: não retoma preview,
inspeção, snapshots ou writes. `stopPassiveDiscovery()`, lock explícito,
desconexão, re-enumeração, sleep e terminação usam a mesma transição idempotente
para estado seguro: desabilitam a trava de escrita, cancelam inspeção, refresh
de selector, snapshots e writes com debounce, descartam resultados obsoletos,
invalidam o transporte antes de ativar uma substituição e param o preview quando
necessário. O token `locationID`/`registryID`/geração impede que trabalho
atrasado alcance uma câmera re-enumerada na mesma porta.

A descoberta passiva distingue:

- **Pocket 4 confirmada:** o par VID `0x2CA3`/PID `0x0023` e uma identidade de
  produto publicada contendo `OsmoPocket4`; é o único perfil que pode chegar
  ao preview, às leituras UVC e, após opt-in explícito, a writes UVC padrão.
- **Família DJI Osmo Pocket detectada:** fabricante/VID DJI e nome de produto
  compatível; o app mostra a presença do dispositivo, mas bloqueia preview,
  inspeção e qualquer write até que exista um perfil de protocolo validado.

Se houver mais de uma câmera DJI externa, o fallback de nome genérico não
escolhe uma delas de forma ambígua. Isso evita associar controles da Pocket 4
a outra câmera conectada.

## Status de conexão e menu bar

`PocketConnectionPresentationState` é a única projeção de status usada pela
menu bar e pelo cabeçalho de Diagnostics. Ela deriva texto, símbolo SF,
severidade visual, próxima ação segura e rótulo conciso para VoiceOver a partir
da fase de descoberta passiva, perfil USB, histórico de desconexão da execução,
autorização de câmera sem prompt, visibilidade AVFoundation somente-leitura e
resultado já armazenado da inspeção direta UVC.

As views não consultam IORegistry, AVFoundation, logs, preview ou a ponte UVC
para adivinhar a conexão. Renderizar o estado não pede TCC, não inicia preview,
não abre transporte e não faz requests UVC. O indicador visual de severidade é
suplementar: o símbolo, o título e o rótulo de acessibilidade comunicam o
estado sem depender de cor.

As únicas ações da menu bar são **Refresh Detection**, que solicita um novo
snapshot ao monitor passivo já existente, e **Open Diagnostics**, que abre a
janela de laboratório. Nenhuma delas inicia inspeção UVC ou preview. A
disponibilidade UVC direta permanece `unknown` até uma inspeção somente-leitura
iniciada explicitamente pelo operador; o resultado armazenado é associado à
geração da conexão atual e é descartado em desconexão ou reenumeração.

## APIs usadas

- Swift e SwiftUI para a janela e a interface.
- AVFoundation para solicitar acesso a vídeo e exibir somente preview.
- CoreMediaIO para observar controles que o driver macOS eventualmente expõe.
- IOKit/IORegistry para identidade USB, estado e velocidade publicados pelo
  sistema.
- IOUSBLib somente como ponte estreita para requests UVC de classe, quando o
  macOS disponibilizar um user client. `IOUSBHost` não é usado porque sua API
  de inicialização pressupõe ownership exclusivo.

## Como executar

1. Abra [PocketControlLab.xcodeproj](../PocketControlLab.xcodeproj) no Xcode.
2. Selecione o scheme `PocketControlLab` e o destino **My Mac**.
3. Conecte a Pocket 4 por USB-C e selecione **Webcam Mode** na câmera.
4. Execute o app. Ele inicia somente a descoberta passiva, sem solicitar
   permissão, iniciar preview ou fazer requests UVC.
5. Use o status da menu bar ou o cabeçalho de Diagnostics para confirmar a
   evidência de conexão apresentada pelo `DeviceSession`; os detalhes USB
   publicados pelo IORegistry permanecem no Diagnostics.
6. Se desejar preview, escolha **Start Preview**; aceite a permissão de câmera
   somente se o macOS a solicitar após essa ação.
7. Use **Refresh Read-Only Inspection** para iniciar uma inspeção UVC somente-leitura
   manual. Desbloqueie writes apenas quando estiver pronto para observar a
   câmera e registrar o resultado.

Após abrir uma revisão do projeto que altere a estrutura de grupos, feche e
reabra o projeto no Xcode antes de executar. Isso recarrega o Project
Navigator; os grupos `App`, `Models`, `Camera`, `USB`, `Investigation`, `UI`,
`Resources` e `Docs` representam as pastas reais no disco, não atalhos.

O projeto contém `NSCameraUsageDescription`. O sandbox está deliberadamente
fora do escopo desta primeira ferramenta de laboratório: antes de distribuí-la
seria necessário avaliar entitlement/capability e acesso IOKit em um contexto
sandboxed. Não há entitlement de rede e o app não realiza tráfego de rede.

Para uma build pública, consulte também [PRIVACY.md](../PRIVACY.md),
[SECURITY.md](../SECURITY.md) e [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).
Para a visão de produto, histórico sanitizado e registro dos próximos testes,
consulte [PRODUCT_DIRECTION.md](PRODUCT_DIRECTION.md),
[ENGINEERING_HISTORY.md](ENGINEERING_HISTORY.md) e
[EXPERIMENT_LOG.md](EXPERIMENT_LOG.md).

## Fluxo UVC seguro

Na inicialização, o app não faz request UVC. **Refresh Read-Only Inspection** é uma
ação manual e, para a conexão Pocket 4 confirmada atual, faz somente as
leituras permitidas:

- Camera Terminal, entidade 1/interface VideoControl 0: `GET_INFO`,
  `GET_MIN`, `GET_MAX`, `GET_RES`, `GET_DEF`, `GET_CUR` para Zoom Absolute
  (`0x0B`), Pan/Tilt Absolute (`0x0D`) e Roll Absolute (`0x0F`).
- DJI Extension Unit, entidade 6: `GET_INFO`, `GET_LEN` e, apenas se o tamanho
  retornado for válido, `GET_CUR` para os selectors candidatos 1, 2 e 3.

Se, e somente se, os GETs diretos retornarem um range completo, válido e
`GET_INFO` anunciar GET+SET, a ação explícita de desbloquear writes pode ser
usada manualmente. Há uma segunda trava no transporte: ela começa desligada e
rejeita todo `SET_CUR` até o desbloqueio explícito estar ligado. As únicas
escritas possíveis no código são `SET_CUR` para os três controles Camera
Terminal acima.

Para Pan/Tilt o payload UVC é validado como dois `Int32` little-endian. A
alteração de um eixo lê/preserva o outro eixo por `GET_CUR`; nunca zera o eixo
parceiro. Reset usa exclusivamente o valor recebido por `GET_DEF`.

Cada tentativa de write registra valor antigo, valor solicitado, resposta e
`GET_CUR` posterior. Para Pan/Tilt/Roll o log inclui: “Please visually verify
whether the physical gimbal moved.”

## Extension Unit e snapshots

O descriptor anterior indica Unit ID 6 e GUID
`41769EA2-04DE-E347-8B2B-F4341AFF003B`. Ele é inconsistente:
`bNumControls = 2`, mas `bmControls = 0x07`. Por isso os selectors 1, 2 e 3
são mostrados como candidatos; não são tratados como comandos conhecidos.

Não existe caminho de `SET_CUR` para a Extension Unit nesta versão. **Capture
Snapshot A** e **Capture Snapshot B** preservam os bytes de `GET_CUR` de cada
selector e mostram o diff por byte. São ações explícitas do operador, nunca
efeitos da descoberta passiva. O procedimento é capturar A, alterar algo
manualmente na tela da Pocket, capturar B e observar apenas as diferenças, sem
inferir semântica automaticamente.

## Resultados reais já registrados

Os dados abaixo foram registrados em testes reais ou em builds locais. Campos
de identificação única do dispositivo e da máquina foram redigidos antes da
publicação do repositório. Resultados ainda não capturados por controle devem
continuar marcados como não verificados.

- O projeto foi compilado com sucesso pelo Xcode 26.6 em Debug (arm64 e build
  padrão) e Release. O bundle não foi iniciado durante esta preparação,
  portanto nenhuma permissão TCC, preview, GET ou SET deste app foi executado
  como parte desses builds.
- O bundle Debug arm64 foi verificado com assinatura ad-hoc local. O bundle ID
  de código-fonte é `org.pocketcontrollab.PocketControlLab`; isso ainda não é
  uma assinatura Developer ID, distribuição ou notarização.
- Em 2026-09-02, o build Release universal (`arm64` + `x86_64`) passou em
  `codesign --verify --deep --strict` e contém a flag Hardened Runtime. Ele
  continua ad-hoc, sem Team ID, e o Gatekeeper o rejeita; isto não é um
  artefato distribuível até haver assinatura Developer ID e notarização.
- Dispositivo observado: fabricante `DJI`, produto `DJI Osmo Pocket 4`
  (sufixo específico do dispositivo redigido), VID `0x2CA3`, PID `0x0023`,
  USB High-Speed 480 Mb/s, UVC + UAC1.
- Na primeira execução interativa em 2026-08-22, a permissão de câmera foi
  autorizada, mas o bundle Debug então em execução não detectou a Pocket e,
  por consequência, não iniciou a procura AVFoundation. O IORegistry da mesma
  máquina confirmou depois a Pocket conectada com os VID/PID acima. A causa
  era um erro de ciclo no scanner: a liberação adiada podia
  liberar o próximo serviço do iterador antes de ele ser lido. O scanner foi
  corrigido para liberar cada serviço depois de inspecioná-lo. O binário da
  captura era anterior à correção; é necessário rebuild e relançamento para
  validar o fluxo corrigido.
- Em uma execução posterior, a descoberta avançou até iniciar o preview, mas
  o processo encerrou com `AVCaptureSession startRunning may not be called
  between calls to beginConfiguration and commitConfiguration`. A causa foi
  confirmada no código: `startRunning()` ainda estava no escopo da
  configuração. A sessão agora conclui `commitConfiguration()` antes de ser
  iniciada. O build corrigido compilou, mas o preview ainda precisa ser
  validado novamente em execução interativa; este erro não produziu nenhum
  GET/SET UVC.
- O Project Navigator também foi corrigido para usar grupos Xcode que espelham
  as pastas reais. Nenhum arquivo foi movido ou substituído no disco.
- Em teste interativo relatado em 2026-09-02, o operador confirmou preview e
  controle de posicionamento/alteração da câmera pelo Mac, sem tocar na
  câmera. O relatório não registra ainda uma tabela por selector, firmware,
  cabo ou a distinção completa entre movimento físico e PTZ digital; esses
  itens continuam pendentes de captura experimental estruturada.
- Camera Terminal UVC observado: bitmap `00 2A 00`, anunciando os bits 9, 11 e
  13 (Zoom Absolute, Pan/Tilt Absolute e Roll Absolute).
- Extension Unit observada: Unit 6, GUID acima, `bNumControls = 2`,
  `bmControls = 0x07`, source ID 2.
- A investigação inicial não registrou valores individuais de `GET_*`,
  `SET_CUR` ou uma observação por eixo. O sucesso interativo posterior não
  deve ser convertido retrospectivamente em valores ou semânticas que não
  foram salvos.
- Ao tentar criar o user client legado nesta máquina enquanto o driver de vídeo
  estava ativo, `IOCreatePlugInInterfaceForService` retornou
  `0xE00002BE` (`kIOReturnNoResources`) antes de qualquer control transfer.
  Isso é mostrado como bloqueio no app; nenhuma tentativa é feita para matar,
  desativar, abrir à força ou tomar posse de `UVCAssistant`.

## Limitações e erros esperados

- AVFoundation oferece preview e formatos, mas não expõe `videoZoomFactor` no
  macOS para este caso.
- CoreMediaIO pode anunciar objetos de controle, mas não fornece os raw UVC
  `GET_INFO/MIN/MAX/RES/DEF`, os selectors XU ou `GET_LEN`.
- Se o driver macOS retiver a interface e bloquear o user client, os ranges
  raw, XU e sliders ficam desabilitados de forma segura. Este é um resultado de
  compatibilidade importante, não um motivo para forçar ownership.
- Permissão negada, desconexão, stall, short transfer e propriedades ausentes
  são tratados como estado/log, não como crash.

## Próximos experimentos

1. Salvar uma sessão redigida com os GETs diretos, a versão do macOS, firmware
   e cabo, caso o macOS forneça um user client compatível.
2. Habilitar writes somente com ranges completos e executar variações lentas
   (máximo ~13 por segundo) enquanto um operador observa o gimbal.
3. Registrar separadamente: `SET_CUR` aceito, `GET_CUR` posterior e observação
   física/digital/ignorada/erro.
4. Fazer pares de snapshots XU enquanto configurações são alteradas apenas na
   tela da Pocket.
5. Documentar versões de macOS/firmware/cabo e cada erro sem transformar uma
   hipótese em resultado.
6. Repetir os testes em uma build assinada com Developer ID e Hardened Runtime
   antes de prometer compatibilidade de distribuição.

## Limites não negociáveis desta versão

O projeto não contém firmware update, DFU, reset de dispositivo, mudança de
configuração, `USBDeviceOpen`, `USBDeviceOpenSeize`, abertura forçada de
interface, kill/disable de `UVCAssistant`, request vendor-specific, DUML,
Bluetooth, Wi-Fi, DJI Mimo, escrita de memória nem `SET_CUR` de Extension Unit.
