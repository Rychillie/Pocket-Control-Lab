# DJI Osmo Pocket 4 — macOS USB Investigation

> **Nota de privacidade para a versão pública:** identificadores que podem
> vincular esta captura a um dispositivo físico ou a uma topologia USB local
> foram redigidos. A evidência técnica permanece preservada, mas o material
> bruto original deve permanecer privado.

Investigação realizada em 2026-08-22, com a câmera fisicamente conectada por
USB-C em Webcam Mode. Este documento usa apenas observações diretas do Mac e
do dispositivo: IORegistry, logs do driver UVC da Apple, um snapshot nativo de
descriptors e CLIs locais de AVFoundation/CoreMediaIO.

Nenhum `SET_CUR`, comando DJI proprietário, escrita em memória, atualização de
firmware, DFU/recovery, reset ou reconfiguração foi solicitado pelo trabalho.
Também não foram enviados `GET_INFO`, `GET_MIN`, `GET_MAX`, `GET_RES`,
`GET_DEF` ou `GET_CUR` UVC. O snapshot nativo de descriptor é tratado com a
ressalva de segurança documentada em `Next experiments`.

Classificação usada abaixo:

- **SUPPORTED**: demonstrado pelo driver macOS em sua camada de enumeração ou
  formato; não equivale, por si só, a um teste de comando de controle.
- **LIKELY SUPPORTED**: anunciado pelo descriptor, mas sem leitura de valores,
  negociação de stream ou teste de operação correspondente.
- **UNKNOWN**: não pode ser inferido dos dados observados.
- **UNSUPPORTED**: não é anunciado pela configuração UVC atual; quando
  indicado, a conclusão é limitada ao UVC padrão.

## Hardware detected

**SUPPORTED.** O macOS enumerou o dispositivo físico como:

```text
OsmoPocket4-<device-specific-suffix-redacted>@<USB-location-redacted>
```

Ele está conectado pela árvore:

```text
<Mac USB controller>
  └─ <USB high-speed port>
      └─ OsmoPocket4-<device-specific-suffix-redacted>@<USB-location-redacted>
```

O link negociado é **USB High-Speed, 480 Mb/s**, não SuperSpeed. O dispositivo
publica uma configuração ativa chamada `uvc,uac1`, o que confirma Webcam Mode
com UVC + UAC1.

`UVCAssistant`, a extensão UVC nativa da Apple, reconheceu o dispositivo,
associou as interfaces 0/1, detectou `ExtensionUnit=1`, `InterruptPipe=1` e
`StreamPipeBulk=1`, e selecionou H.265 1920×1080 como formato padrão.

`system_profiler SPUSBDataType` retornou vazio neste contexto de execução; isso
não foi tratado como evidência negativa, pois IORegistry e o próprio driver UVC
confirmaram a enumeração física.

## USB identifiers

| Campo | Valor observado |
|---|---|
| Manufacturer | `DJI` |
| Product | `OsmoPocket4-<device-specific-suffix-redacted>` |
| Serial | `<redacted>` |
| Vendor ID | `0x2CA3` (11427) |
| Product ID | `0x0023` (35) |
| `bcdUSB` | `0x0201` (USB 2.01) |
| `bcdDevice` | `0x0504` |
| Device class/subclass/protocol | `0xEF / 0x02 / 0x01` — Miscellaneous/Common Class/IAD composite |
| Endpoint 0 max packet | 64 bytes |
| Configurations | 1; current configuration 1 |
| Power | Bus-powered, 500 mA |
| Location ID | `<redacted>` |

O snapshot nativo apresentou os campos do Device Descriptor, mas não o seu hex
original em uma única linha. Abaixo está a reconstrução canônica dos campos
observados — útil para referência, mas marcada como reconstruída:

```text
12 01 01 02 EF 02 01 40 A3 2C 23 00 04 05 01 02 03 01
```

O BOS Descriptor foi obtido diretamente:

```text
05 0F 0C 00 01 07 10 02 06 00 00 00
```

Ele anuncia uma USB 2.0 Extension Capability com `bmAttributes=0x00000006`,
incluindo Link Power Management. O Device Qualifier foi decodificado como USB
2.01, `EF/02/01`, endpoint 0 de 64 bytes e uma configuração.

## USB interfaces

A configuração ativa tem dois Interface Association Descriptors (IADs): vídeo
nas interfaces 0–1 e áudio nas interfaces 2–4.

| Interface | Alternate setting | Class / subclass / protocol | Descrição | Endpoints declarados no alternate |
|---:|---:|---|---|---|
| 0 | 0 | `0x0E / 0x01 / 0x00` | UVC Video Control | `0x81` IN interrupt |
| 1 | 0 | `0x0E / 0x02 / 0x00` | UVC Video Streaming | `0x82` IN bulk |
| 2 | 0 | `0x01 / 0x01 / 0x00` | USB Audio Class 1.0 Control | nenhum |
| 3 | 0 | `0x01 / 0x02 / 0x00` | Audio Streaming — Playback Inactive | nenhum |
| 3 | 1 | `0x01 / 0x02 / 0x00` | Audio Streaming — playback-capable | `0x01` OUT isochronous |
| 4 | 0 | `0x01 / 0x02 / 0x00` | Audio Streaming — Capture Inactive | nenhum |
| 4 | 1 | `0x01 / 0x02 / 0x00` | Audio Streaming — capture-capable | `0x83` IN isochronous |

Não foi observada na configuração atual nenhuma interface:

- `0xFF` vendor-specific;
- HID;
- CDC/serial;
- rede;
- Mass Storage/MTP.

Portanto, um eventual protocolo DJI proprietário em Webcam Mode não aparece
como uma interface USB separada: a pista real é a UVC Extension Unit descrita
abaixo.

### USB Audio Class 1.0

O Audio Control Header anuncia UAC 1.0 e as duas interfaces de streaming 3 e
4. A topologia é:

- playback: USB Streaming Terminal ID 1 → Speaker Output Terminal ID 2;
- capture: Microphone Input Terminal ID 3 → USB Streaming Output Terminal ID 4.

Ambos os streams ativos anunciam PCM estéreo, 16-bit, 48,000 Hz. Isso confirma
que o Webcam Mode também oferece áudio bidirecional por USB, sem uma interface
serial ou de rede adicional.

## USB endpoints

| Interface / alt | Endpoint | Direção / tipo | `wMaxPacketSize` | `bInterval` | Observação |
|---|---:|---|---:|---:|---|
| EP0 | `0x00` | Control bidirecional | 64 | — | descriptor de dispositivo |
| UVC VC 0/0 | `0x81` | IN interrupt | 16 | 8 | 16 ms em High-Speed; descriptor CS endpoint informa máximo 16 |
| UVC VS 1/0 | `0x82` | IN bulk | 512 | 0 | payload do vídeo no modo High-Speed atual |
| UAC playback 3/1 | `0x01` | OUT isochronous adaptive | 200 | 4 | 1 ms em High-Speed |
| UAC capture 4/1 | `0x83` | IN isochronous adaptive | 200 | 4 | 1 ms em High-Speed |

O Other-Speed Configuration Descriptor também foi exposto. Ele tem a mesma
estrutura de 669 bytes, mas usa tipo `0x07` no Configuration Descriptor e
reduz o endpoint UVC bulk `0x82` para MPS 64, como esperado fora de High-Speed.

## UVC descriptors

### Video Control

| Descriptor | Dados observados |
|---|---|
| VC Header | UVC `0x0100`; total VC 78 bytes; clock 48 MHz; uma interface de streaming (#1) |
| Camera Input Terminal | Unit/Terminal ID 1, tipo `0x0201` Camera; três bytes de controles |
| Processing Unit | Unit ID 2, source ID 1, `wMaxMultiplier=0x4000`; dois bytes de controles |
| Output Terminal | Terminal ID 3, tipo `0x0101` USB Streaming; source ID 2 |
| Extension Unit | Unit ID 6, ligada ao source ID 2 |
| Class-specific endpoint | interrupt transfer size 16 bytes |

Descriptors class-specific relevantes, em bytes crus:

```text
VC Header:       0D 24 01 00 01 4E 00 00 6C DC 02 01 01
Camera Terminal: 12 24 02 01 01 02 00 00 00 00 00 00 00 00 03 00 2A 00
Processing Unit: 0C 24 05 02 01 00 40 02 00 00 00 00
Output Terminal: 09 24 03 03 01 01 00 02 00
VC Endpoint:     05 25 03 10 00
```

### Video Streaming

O VS Input Header anuncia dois formatos, endpoint de payload `0x82`, terminal
link 3 e `bmaControls=0x00` para ambos os formatos. Não há still capture nem
trigger:

```text
VS Header: 0F 24 01 02 6C 01 82 00 03 00 00 00 01 00 00
```

O descriptor de cor anuncia primárias BT.709/sRGB, transferência BT.709 e
matriz SMPTE 170M/BT.601:

```text
06 24 0D 01 01 04
```

Nota de compatibilidade: o VC Header declara `bcdUVC=0x0100`, enquanto o
stream usa os subtipos frame-based `0x10`/`0x11`. O relatório preserva essa
combinação literalmente; ela não deve ser interpretada como prova de suporte
integral a todos os recursos de uma revisão UVC posterior.

## UVC controls

### Camera Terminal — controles anunciados

O bitmap do Camera Terminal é `00 2A 00`. Com os bits UVC contados a partir de
zero, somente três seletores padrão estão ativos:

| Bit | Controle UVC | Classificação | Limite importante |
|---:|---|---|---|
| 9 | `CT_ZOOM_ABSOLUTE_CONTROL` | **LIKELY SUPPORTED** (anunciado) | amplitude, valor atual e efeito físico não foram lidos |
| 11 | `CT_PANTILT_ABSOLUTE_CONTROL` | **LIKELY SUPPORTED** (anunciado) | não prova que moverá o gimbal físico em vez de PTZ lógico |
| 13 | `CT_ROLL_ABSOLUTE_CONTROL` | **LIKELY SUPPORTED** (anunciado) | amplitude e efeito não foram lidos |

Dos bits CT 0–23 cobertos pelos três bytes, somente 9, 11 e 13 estão ativos.
Os bits restantes relevantes estão zerados. Assim, estes controles padrão não
são anunciados pela interface UVC ativa:

| Funcionalidade | Classificação | Evidência |
|---|---|---|
| Exposure / Auto Exposure | **UNSUPPORTED via standard UVC** | sem `CT_AE_MODE`, `CT_AE_PRIORITY` ou `CT_EXPOSURE_TIME_ABSOLUTE` |
| Shutter | **UNSUPPORTED via standard UVC** | sem `CT_EXPOSURE_TIME_ABSOLUTE` |
| ISO | **UNSUPPORTED via standard UVC** | UVC não anuncia ISO direto e o PU não anuncia `GAIN` |
| Focus / Auto Focus | **UNSUPPORTED via standard UVC** | sem `CT_FOCUS_ABSOLUTE`, `CT_FOCUS_RELATIVE` ou `CT_FOCUS_AUTO` |
| Iris | **UNSUPPORTED via standard UVC** | sem controles CT de iris |
| Zoom relative | **UNSUPPORTED via standard UVC** | sem `CT_ZOOM_RELATIVE` |
| Pan/tilt relative | **UNSUPPORTED via standard UVC** | sem `CT_PANTILT_RELATIVE` |
| Roll relative | **UNSUPPORTED via standard UVC** | sem `CT_ROLL_RELATIVE` |
| Privacy | **UNSUPPORTED via standard UVC** | bit de privacy zerado |

### Processing Unit — controles anunciados

O bitmap do Processing Unit é `00 00`: todos os bits PU 0–15 estão claros.
Nenhum controle PU padrão é anunciado:

| Funcionalidade | Classificação |
|---|---|
| Brightness | **UNSUPPORTED via standard UVC** |
| Contrast | **UNSUPPORTED via standard UVC** |
| Hue | **UNSUPPORTED via standard UVC** |
| Saturation | **UNSUPPORTED via standard UVC** |
| Sharpness | **UNSUPPORTED via standard UVC** |
| Gamma | **UNSUPPORTED via standard UVC** |
| White Balance manual/auto | **UNSUPPORTED via standard UVC** |
| Backlight Compensation | **UNSUPPORTED via standard UVC** |
| Gain | **UNSUPPORTED via standard UVC** |
| Power Line Frequency | **UNSUPPORTED via standard UVC** |
| Contrast Auto | **UNSUPPORTED via standard UVC** |

### Valores e ranges UVC

| Operação | Estado |
|---|---|
| `GET_INFO` | **UNKNOWN / não consultado** |
| `GET_MIN` | **UNKNOWN / não consultado** |
| `GET_MAX` | **UNKNOWN / não consultado** |
| `GET_RES` | **UNKNOWN / não consultado** |
| `GET_DEF` | **UNKNOWN / não consultado** |
| `GET_CUR` | **UNKNOWN / não consultado** |

Embora sejam semanticamente leituras, esses requests adicionais iriam para uma
interface que está em uso exclusivo por `UVCAssistant`. Para preservar a regra
de não perturbar a câmera, esta etapa se limitou a descriptors já publicados.

## Extension Units

**SUPPORTED: existe uma UVC Extension Unit real.**

| Campo | Valor |
|---|---|
| Unit ID | 6 |
| GUID | `41769EA2-04DE-E347-8B2B-F4341AFF003B` |
| GUID wire bytes | `A2 9E 76 41 DE 04 47 E3 8B 2B F4 34 1A FF 00 3B` |
| `bNumControls` | 2 |
| `bNrInPins` | 1 |
| Source IDs | 2 |
| `bControlSize` | 1 |
| `bmControls` | `0x07` |
| `iExtension` | 0 (sem nome) |

Raw descriptor:

```text
1A 24 06 06 A2 9E 76 41 DE 04 47 E3 8B 2B F4 34
1A FF 00 3B 02 01 02 01 07 00
```

Há uma anomalia objetiva: `bNumControls=2`, mas `bmControls=0x07` possui três
bits ativos (0, 1 e 2). Nenhuma semântica foi inferida para esses bits.

Isso é a melhor pista atual para funções DJI proprietárias. Ela usa o canal
UVC de controle padrão (não uma interface `0xFF` nem um endpoint bulk dedicado)
e pode conter gimbal, recenter, tracking ou controles de imagem — mas todos
esses significados continuam **UNKNOWN** até uma investigação explicitamente
aprovada da XU.

## Video formats

### Format 1 — MJPEG

| Frame | Resolução | Bitrate mínimo/máximo | Buffer máximo | Intervalos discretos |
|---:|---|---:|---:|---|
| 1 | 1920×1080 | 32,000,000 / 96,000,000 b/s | 1,843,200 | 333333, 400000, 416666 (30/25/24 fps nominais) |
| 2 | 1080×1920 | 32,000,000 / 96,000,000 b/s | 1,843,200 | 333333, 400000, 416666 (30/25/24 fps nominais) |
| 3 | 3840×2160 | 111,974,400 / 223,948,800 b/s | 3,732,480 | 333333, 400000, 416666 (30/25/24 fps nominais) |
| 4 | 1728×3072 | 111,974,400 / 223,948,800 b/s | 3,732,480 | 333333, 400000, 416666 (30/25/24 fps nominais) |

### Format 2 — Frame-based H.265 / HEVC

O GUID `35363248-0000-0010-8000-00AA00389B71` contém FourCC `H265` no
layout UVC. Ele anuncia as mesmas quatro resoluções, bitrates e intervalos do
MJPEG acima. O descriptor frame-based também informa `dwBytesPerLine=0`.

O driver da Apple confirmou por log que escolheu, por padrão:

```text
1920 × 1080, H.265, subtype 0x10, frame interval 333333
```

Logo, o modo padrão é 30 fps nominal; o maior intervalo anunciado é 416666,
equivalente a 24 fps nominal.

| Capacidade | Classificação | Evidência |
|---|---|---|
| Video preview UVC | **LIKELY SUPPORTED** | VS bulk, dois formatos e seleção interna do driver; nenhum stream foi iniciado neste trabalho |
| MJPEG | **LIKELY SUPPORTED** | VS format index 1 |
| H.265 / HEVC | **LIKELY SUPPORTED** | VS frame-based format index 2 + log do driver |
| 3840×2160 | **LIKELY SUPPORTED** | frame descriptor em ambos os formatos |
| 1728×3072 vertical | **LIKELY SUPPORTED** | frame descriptor em ambos os formatos |
| YUY2 | **UNSUPPORTED como formato UVC nativo** | não anunciado |
| NV12 | **UNSUPPORTED como formato UVC nativo** | não anunciado |
| H.264 | **UNSUPPORTED como formato UVC nativo** | não anunciado |
| HDR | **UNKNOWN** | não há descriptor/HDR metadata específico exposto |
| Still-image capture/trigger UVC | **UNSUPPORTED** | `bStillCaptureMethod=0`, trigger não suportado |

O macOS pode, após decodificação, entregar um pixel buffer diferente (por
exemplo NV12) a uma aplicação AVFoundation. Essa possibilidade de conversão é
**UNKNOWN** nesta sessão TCC-negada e não altera os formatos nativos UVC acima.

## AVFoundation capabilities

Foi criado o CLI seguro [main.swift](Tools/PocketInspector/main.swift).
Ele somente enumera dispositivos e propriedades; não cria capture session,
não inicia stream, não bloqueia configuração e não chama setters.

Resultado observado no processo desta investigação:

| Consulta | Resultado |
|---|---|
| `AVCaptureDevice.authorizationStatus(for: .video)` | `denied` |
| Video devices visíveis na DiscoverySession deste processo | 0 |
| Formatos, pixel formats, frame-rate ranges | não observáveis neste processo |
| Focus/exposure/white-balance support flags | não observáveis neste processo |
| `ffmpeg -f avfoundation -list_devices true -i ""` | cabeçalhos vazios e erro de abertura esperado |

O resultado é compatível com uma limitação de TCC/visibilidade do processo,
mas a causalidade não foi isolada nesta etapa. De todo modo, ele **não** é uma
conclusão de que a câmera não existe: o IORegistry e `UVCAssistant` provaram a
enumeração UVC. Após conceder permissão de câmera a um processo apropriado, o
mesmo CLI poderá tentar listar `localizedName`, ID único, transport type,
formatos, frame-rate ranges e as flags AVFoundation que o macOS decidir expor.

## CoreMediaIO capabilities

O mesmo CLI consultou `kCMIOHardwarePropertyDevices` somente por getters e não
obteve um device CMIO visível no contexto que também reportou TCC `denied`.
O helper representa ausência, erro de propriedade e lista vazia como uma lista
vazia; portanto, isso não prova que o sistema CMIO global tenha zero devices.
Nenhum objeto de controle CoreMediaIO ou capacidade PTZ ficou observável para
este processo.

Ainda assim, o driver CoreMediaIO/UVC está ativo e fornece estes fatos diretos:

- bundle publicado: `com.apple.cmio.uvcassistantextension`;
- `UVCAssistant` possui as interfaces UVC 0 e 1;
- interface de control interrupt com MPS 16 foi agendada;
- interface de streaming bulk foi reconhecida;
- formato padrão H.265 1920×1080 foi selecionado internamente.

O matching genérico `UVCMatching-ExternalCamera` também publicou:

```text
UVCCameraHideControls = ({ UVCControlEntityType = 3; })
```

Essa é uma regra genérica do driver para câmeras UVC externas. Ela indica que
um tipo de entidade é ocultado nos controles genéricos do assistente; não foi
usada para atribuir significado ao número 3 nem para afirmar que a XU será
exposta em AVFoundation/CoreMediaIO.

**PTZ no macOS:** o hardware anuncia Pan/Tilt absoluto e Roll absoluto por
UVC, mas a camada AVFoundation/CoreMediaIO não ficou observável neste processo.
Portanto, PTZ é **LIKELY SUPPORTED pelo descriptor UVC** e **UNKNOWN quanto à
sua publicação prática por AVFoundation/CoreMediaIO nesta sessão**.

## Vendor-specific interfaces

Não há interface USB de classe `0xFF` no Webcam Mode observado. Também não há
HID, CDC, serial, rede, Mass Storage ou endpoint separado destinado a comandos
DJI.

A UVC Extension Unit ID 6 é a única entidade de controle explicitamente
vendor-defined anunciada. Ela é encapsulada em UVC padrão e seus control
selectors são opacos; isso não exclui metadados no payload de vídeo ou canais
em outros modos USB. Logo:

| Possível via USB | Classificação |
|---|---|
| Vídeo e áudio UVC/UAC | **SUPPORTED** |
| Zoom/PanTilt/Roll pelo UVC padrão | **LIKELY SUPPORTED** como capability anunciada; valores/efeito ainda não testados |
| Comandos DJI via interface `0xFF` | **UNSUPPORTED neste Webcam Mode** |
| Comandos DJI via UVC XU | **LIKELY SUPPORTED**, porém sem semântica conhecida |

## Interesting findings

- A câmera é uma composição UVC + UAC1 limpa em USB 2.0 High-Speed, apesar do
  conector USB-C.
- Ela anuncia H.265 frame-based e MJPEG, ambos até 4K 30 fps nominal, sem
  formatos raw/uncompressed anunciados.
- O UVC padrão é bastante limitado em imagem: o Camera Terminal só anuncia
  zoom/pan-tilt/roll, e o Processing Unit não anuncia nenhum controle.
- Há uma XU DJI real, com GUID fixo e bitmap de controles não autoexplicativo.
  Ela é a rota técnica mais promissora para recursos além de PTZ.
- O descriptor da XU é internamente inconsistente (`bNumControls=2` versus
  bitmap `0x07`), portanto um controlador futuro deve validar o comportamento
  com leituras conservadoras antes de assumir que há dois ou três selectors.
- O driver UVC da Apple usa um formato H.265 padrão 1920×1080/30 fps, o que
  dá uma confirmação independente do decoder de descriptor.
- A ausência de dispositivos visíveis em AVFoundation/CoreMediaIO ocorreu no
  mesmo processo que reportou TCC negado; a causalidade não foi isolada e não
  deve ser confundida com falha de enumeração física.

## Controls potentially available over USB

| Função | Classificação | Fonte |
|---|---|---|
| Preview de vídeo | **SUPPORTED na camada do driver** | UVC VS + formato padrão selecionado por `UVCAssistant`; acesso pela app ainda não foi testado |
| Seleção MJPEG/H.265 e dos formatos anunciados | **LIKELY SUPPORTED** | VS descriptors; negociação normal de stream ainda não foi exercitada por este trabalho |
| Zoom absoluto | **LIKELY SUPPORTED** | bit CT UVC anunciado; sem `GET_*`/`SET_CUR` |
| Pan/Tilt absoluto | **LIKELY SUPPORTED** | bit CT UVC anunciado; sem `GET_*`/`SET_CUR` |
| Roll absoluto | **LIKELY SUPPORTED** | bit CT UVC anunciado; sem `GET_*`/`SET_CUR` |
| Movimento físico do gimbal | **UNKNOWN** | Pan/Tilt/Roll UVC pode representar PTZ lógico, gimbal físico ou ambos |
| Gimbal recenter | **UNKNOWN** | sem selector padrão; XU pode ou não conter a função |
| Tracking | **UNKNOWN** | sem selector padrão; XU pode ou não conter a função |
| Áudio de captura estéreo 48 kHz | **SUPPORTED** | UAC1 capture descriptor |
| Áudio de playback estéreo 48 kHz | **SUPPORTED** | UAC1 playback descriptor |
| Controles DJI proprietários | **LIKELY SUPPORTED** | XU presente; selectors sem semântica |

## Controls apparently unavailable over USB

As conclusões desta seção se aplicam à **interface UVC padrão no Webcam Mode
atual**. Uma capacidade pode ainda existir atrás da XU, em outro modo USB ou em
outro transporte; não foi presumido que ela inexiste na câmera inteira.

| Função | Classificação no UVC padrão atual |
|---|---|
| Auto exposure / exposure / shutter | **UNSUPPORTED** |
| ISO / gain | **UNSUPPORTED** |
| Focus / autofocus | **UNSUPPORTED** |
| White balance | **UNSUPPORTED** |
| Brightness / contrast / saturation / sharpness | **UNSUPPORTED** |
| H.264 / YUY2 / NV12 | **UNSUPPORTED** como formatos anunciados |
| Still capture/trigger | **UNSUPPORTED** |
| Interface de comando vendor-specific separada | **UNSUPPORTED** |

## Unknown / needs further investigation

- ranges, resolução e valores correntes de Zoom/PanTilt/Roll (`GET_*` não
  foram enviados);
- se Pan/Tilt/Roll move o gimbal físico, uma janela digital ou ambos;
- significado e número efetivo de selectors da XU;
- gimbal recenter;
- tracking;
- exposição, foco, ISO, white balance ou outros ajustes escondidos na XU;
- capacidades HDR reais;
- quais formatos e controles AVFoundation/CoreMediaIO publicam após uma
  autorização de câmera válida;
- quais interfaces aparecem em File Transfer Mode ou em outros modos USB.

## Next experiments

Nenhum destes passos foi executado automaticamente.

1. **Repetir o AVFoundation/CoreMediaIO inspector com permissão de câmera
   concedida ao processo escolhido.** Isso permitirá observar a camada que um
   futuro app macOS realmente receberá, sem precisar controlar a câmera.
2. **Planejar uma etapa UVC read-only separada.** Com aprovação explícita,
   projetar um cliente que não interrompa `UVCAssistant` e consulte somente
   `GET_INFO`, `GET_MIN`, `GET_MAX`, `GET_RES`, `GET_DEF` e `GET_CUR` para
   Zoom/PanTilt/Roll e para a XU. Nunca incluir `SET_CUR` nessa fase.
3. **Repetir o snapshot quando o usuário selecionar manualmente File Transfer
   Mode.** Procurar MTP/PTP, Mass Storage, HID, CDC, rede ou uma nova interface
   `0xFF`. Depois, retornar manualmente a Webcam Mode e comparar descriptors.
4. **Repetir também em conexão USB-C normal/charging**, apenas se a própria
   câmera oferecer esse modo, para comparar PID, interfaces e endpoints.
5. **Monitorar eventos antes de investigar payloads.** Usar snapshots
   `ioreg`, `usbdiagnose --busprobe` com cautela, e `log stream` filtrado para
   `UVCAssistant`/`com.apple.UVCFamily` em um Terminal normal. Isso mostra
   lifecycle e decisões do driver, não o conteúdo de transfers.
6. **Para observação Mac ↔ câmera em nível de pacote**, planejar um analisador
   USB 2.0 físico inline. PacketLogger e USB Prober.app não estão instalados;
   Instruments/xctrace e Unified Logging não foram confirmados como sniffers
   de payload USB genéricos.

### Nota de segurança sobre `usbdiagnose`

O snapshot completo foi obtido por `/usr/bin/usbdiagnose --busprobe`, invocado
com intenção de diagnosticar descriptors e sem parâmetros que solicitem
alteração de estado, UVC, vendor, firmware ou memória. Não instrumentamos o
barramento para provar o que o binário faz internamente. Seus símbolos incluem
caminhos que podem chamar `USBDeviceOpen` em outros fluxos; portanto, ele deve
ser usado somente com cautela e autorização explícita em experiências futuras.
Ele não tem a mesma fronteira auditável do inspector C deste repositório. No
run atual, o inspector C parou antes de `QueryInterface` e antes de
`GetConfigurationDescriptorPtr(0)`; ele não chamou `USBDeviceOpen`, mas também
não deve ser apresentado como uma prova genérica de “zero transfer” do
framework subjacente.

## Recommended architecture for a future macOS controller

```text
SwiftUI/AppKit UI
        │
        ├── AVFoundation preview/capture
        │     └── usa o dispositivo UVC após autorização TCC
        │
        ├── UVC standard-control adapter
        │     └── Zoom / PanTilt / Roll apenas após validar GET_* e ownership
        │
        ├── DJI UVC Extension Unit adapter
        │     └── discovery/read-only primeiro; comandos separados por feature flag
        │
        └── Optional alternate transport adapter
              └── BLE/Wi-Fi somente se a XU não expuser gimbal/recenter/tracking
```

O controlador deve manter o preview separado do transporte de controle e deve
tratar a XU como experimental: logs, feature flag, validação de ranges e
nenhuma escrita até existir um protocolo verificado. Como a UVC padrão anuncia
vídeo e apenas três controles de movimento, a melhor conclusão atual é:

> **Scenario B — USB fornece vídeo e poucos controles.**
>
> Há Zoom/PanTilt/Roll UVC anunciados e uma XU promissora, mas exposição,
> foco, white balance e controles de imagem não estão presentes no UVC padrão.
> Se a XU não cobrir gimbal/recenter/tracking, o próximo transporte a
> investigar deverá ser BLE/Wi-Fi usado pelo ecossistema DJI.

## Appendix A — complete current High-Speed Configuration Descriptor

O blob abaixo foi lido da configuração atual de 669 bytes (`wTotalLength =
0x029D`). Ele contém Configuration, IAD, Interface, Endpoint, UVC class-specific
e UAC class-specific descriptors completos para o Webcam Mode observado.

```text
0000: 09 02 9D 02 05 01 04 80 FA 08 0B 00 02 0E 03 00
0010: 05 09 04 00 00 01 0E 01 00 05 0D 24 01 00 01 4E
0020: 00 00 6C DC 02 01 01 12 24 02 01 01 02 00 00 00
0030: 00 00 00 00 00 03 00 2A 00 0C 24 05 02 01 00 40
0040: 02 00 00 00 00 09 24 03 03 01 01 00 02 00 1A 24
0050: 06 06 A2 9E 76 41 DE 04 47 E3 8B 2B F4 34 1A FF
0060: 00 3B 02 01 02 01 07 00 07 05 81 03 10 00 08 05
0070: 25 03 10 00 09 04 01 00 01 0E 02 00 06 0F 24 01
0080: 02 6C 01 82 00 03 00 00 00 01 00 00 0B 24 06 01
0090: 04 00 01 00 00 00 00 26 24 07 01 00 80 07 38 04
00A0: 00 48 E8 01 00 D8 B8 05 00 20 1C 00 15 16 05 00
00B0: 03 15 16 05 00 80 1A 06 00 9A 5B 06 00 26 24 07
00C0: 02 00 38 04 80 07 00 48 E8 01 00 D8 B8 05 00 20
00D0: 1C 00 15 16 05 00 03 15 16 05 00 80 1A 06 00 9A
00E0: 5B 06 00 26 24 07 03 00 00 0F 70 08 00 98 AC 06
00F0: 00 30 59 0D 00 F4 38 00 15 16 05 00 03 15 16 05
0100: 00 80 1A 06 00 9A 5B 06 00 26 24 07 04 00 C0 06
0110: 00 0C 00 98 AC 06 00 30 59 0D 00 F4 38 00 15 16
0120: 05 00 03 15 16 05 00 80 1A 06 00 9A 5B 06 00 1C
0130: 24 10 02 04 48 32 36 35 00 00 10 00 80 00 00 AA
0140: 00 38 9B 71 00 01 00 00 00 00 00 26 24 11 01 00
0150: 80 07 38 04 00 48 E8 01 00 D8 B8 05 15 16 05 00
0160: 03 00 00 00 00 15 16 05 00 80 1A 06 00 9A 5B 06
0170: 00 26 24 11 02 00 38 04 80 07 00 48 E8 01 00 D8
0180: B8 05 15 16 05 00 03 00 00 00 00 15 16 05 00 80
0190: 1A 06 00 9A 5B 06 00 26 24 11 03 00 00 0F 70 08
01A0: 00 98 AC 06 00 30 59 0D 15 16 05 00 03 00 00 00
01B0: 00 15 16 05 00 80 1A 06 00 9A 5B 06 00 26 24 11
01C0: 04 00 C0 06 00 0C 00 98 AC 06 00 30 59 0D 15 16
01D0: 05 00 03 00 00 00 00 15 16 05 00 80 1A 06 00 9A
01E0: 5B 06 00 06 24 0D 01 01 04 07 05 82 02 00 02 00
01F0: 08 0B 02 03 01 00 00 08 09 04 02 00 00 01 01 00
0200: 08 0A 24 01 00 01 34 00 02 03 04 0C 24 02 01 01
0210: 01 00 02 03 00 0A 09 09 24 03 02 01 03 00 01 0B
0220: 0C 24 02 03 01 02 00 02 03 00 0D 0C 09 24 03 04
0230: 01 01 00 03 0E 09 04 03 00 00 01 02 00 0F 09 04
0240: 03 01 01 01 02 00 10 07 24 01 01 01 01 00 0B 24
0250: 02 01 02 02 10 01 80 BB 00 09 05 01 09 C8 00 04
0260: 00 00 07 25 01 01 01 01 00 09 04 04 00 00 01 02
0270: 00 11 09 04 04 01 01 01 02 00 12 07 24 01 04 01
0280: 01 00 0B 24 02 01 02 02 10 01 80 BB 00 09 05 83
0290: 09 C8 00 04 00 00 07 25 01 01 00 00 00
```

## Appendix B — Device Qualifier and Other-Speed descriptor coverage

O snapshot também decodificou o Device Qualifier. A ferramenta não imprimiu
seu hex de origem como uma linha separada; a reconstrução canônica de seus
campos observados é a seguinte, marcada como reconstruída:

```text
0A 06 01 02 EF 02 01 40 01 00
```

O Other-Speed Configuration Descriptor completo de 669 bytes foi acessível no
mesmo snapshot. Para preservar o blob sem duplicar 669 bytes quase idênticos,
ele é definido de forma lossless por uma cópia exata do Appendix A com somente
estas três substituições, confirmadas pelo descriptor observado:

```text
offset 0x0001: 02 → 07  (Other-Speed Configuration Descriptor)
offset 0x01ED: 00 → 40  (wMaxPacketSize baixo de endpoint 0x82)
offset 0x01EE: 02 → 00  (wMaxPacketSize alto de endpoint 0x82)
```

Todos os outros bytes são iguais ao Appendix A. Portanto, o endpoint bulk
`0x82` passa de `0x0200` (512, High-Speed atual) para `0x0040` (64) no
Other-Speed descriptor.
