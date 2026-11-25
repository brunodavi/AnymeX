# Servidor DLNA local (protótipo)

Protótipo isolado que transforma o Android em um **servidor UPnP/DLNA
MediaServer** e publica o vídeo atual do AnymeX como um arquivo virtual na rede
local. O objetivo é permitir que o **Roku Media Player** encontre o conteúdo,
sem exigir que a TV atue como DLNA Renderer e sem alterar o Cast existente.

## Como funciona

1. O botão **Cast** abre o painel existente (`CastDevicePane`).
2. O card **Servidor DLNA local** chama
   `LocalDlnaServer.start()` com a fonte atual
   (`selectedVideo.url` / `offlineVideoPath`, headers, legenda e título).
3. `CastProxyServer` (já usado pelo Cast) expõe a mídia em
   `http://IP_DO_ANDROID:PORTA/video` (ou `/hls/master.m3u8`), repassando
   `HEAD`, `GET`, `Range` e os headers originais. **Nada é baixado por completo
   antes da reprodução.**
4. Um pequeno servidor HTTP UPnP entrega:
   - `/description.xml` (MediaServer:1 + ContentDirectory + ConnectionManager)
   - `/ContentDirectory.xml` e `/ConnectionManager.xml`
   - `/control/ContentDirectory` (Browse, GetSystemUpdateID, capabilities)
   - `/control/ConnectionManager` (GetProtocolInfo)
5. O SSDP anuncia o servidor (`NOTIFY ssdp:alive`) e responde `M-SEARCH` para
   `upnp:rootdevice`, o UUID, `MediaServer:1`, `ContentDirectory:1` e
   `ConnectionManager:1` em `239.255.255.250:1900`.
6. O `Browse` retorna DIDL-Lite com um container `Videos` e um item cujo `<res>`
   aponta para a URL do proxy. O MIME type vem da extensão, de um `HEAD` ou
   de no máximo 512 bytes de um `GET` com `Range` (magic bytes `ftyp`/EBML).
   O `<res>` também inclui `size`, `duration` e `bitrate` (bytes/segundo),
   calculados a partir do `Content-Length` real e da duração do episódio.
   São oferecidas duas variantes: `DLNA.ORG_CI=0;DLNA.ORG_OP=01` e a forma
   UPnP simples, apontando para a mesma URL. Formatos desconhecidos são
   anunciados como `application/octet-stream` (nunca como MP4 falso).
7. Ao trocar de episódio/faixa, o painel chama `updateSource()` e reanuncia o
   servidor, atualizando a URL virtual.

Nenhuma transcodificação é feita. Nenhum comando DLNA Renderer (Play/Stop/ Seek
remoto) é implementado neste protótipo.

## Arquivos

- Novo: `lib/services/cast/local_dlna_server.dart`
- Novo: `docs/local-dlna-server.md`
- Modificado: `lib/services/cast/widgets/cast_device_dialog.dart`
- Modificado: `lib/services/cast/cast_proxy_server.dart` (HEAD correto e MIME
  real para arquivos locais; fallback honesto para fontes remotas)

Nenhuma dependência nova foi adicionada. A implementação é Dart puro
(`dart:io`, `http`, `get`), seguindo o código de Cast já existente — não foi
necessário tocar no Kotlin nem no player (mpv via `media_kit`).

## Como compilar e instalar

O workflow `apk.yml` já gera APKs release assinados com a chave de teste:

1. No GitHub do fork, execute o workflow **Build and Release AnymeX (Android
   APK)**.
2. Baixe `AnymeX-Android-arm64-v8a.apk` (ou o universal) da release fixa `apk`.
3. No Android: **desinstale a versão anterior** (a assinatura de teste é
   diferente) e instale o APK.
4. Celular e TV precisam estar na **mesma rede Wi-Fi** e o Android não pode
   estar em uma rede de convidado com isolamento de cliente.

## Procedimento de teste na AOC Roku TV (Roku OS 16)

1. Abra o AnymeX e inicie qualquer episódio que seja MP4/MKV progressivo (o
   caso mais confiável para o primeiro teste).
2. Toque no botão **Cast** no player.
3. Toque em **Servidor DLNA local → Iniciar**. O painel mostra a URL, por
   exemplo `http://192.168.1.23:41235/video`.
4. Na TV, abra o **Roku Media Player**.
5. Selecione a fonte de mídia em rede. O dispositivo deve aparecer como
   **AnymeX (Servidor DLNA local)**.
6. Navegue em **Videos** e selecione o título do episódio.
7. Confira: reprodução, `GET` com `Range` (busca na linha do tempo) e exibição
   da legenda quando disponível (`/subtitles.vtt`).

Se a TV não aparecer imediatamente, feche e reabra o Roku Media Player (a
descoberta SSDP acontece na abertura da lista de fontes). O servidor reenvia
`NOTIFY` a cada 25 segundos.

A reprodução automática via DLNA não é parte do protótipo: o Roku Media Player
sempre inicia a reprodução pelo usuário. A ECP do Roku (`launch/15985`) usada
pelo Cast atual continua disponível para os dispositivos já descobertos.

### Fontes HLS (`.m3u8`)

O proxy já republica o HLS em `/hls/master.m3u8` reescrevendo variantes,
segmentos, chaves e legendas, sem baixar o vídeo inteiro. Porém o **Roku Media
Player** não é um cliente HLS confiável via navegação DLNA — ele trata `.m3u8`
como playlist e costuma falhar mesmo com `bitrate` correto.

O Roku, por outro lado, reproduz HLS muito bem pela própria plataforma via
**ECP** (`POST http://TV:8060/launch/15985?u=...&videoFormat=hls`), que já é
usada pelo Cast existente. Por isso, quando a fonte atual é m3u8, o painel
mostra o botão **Enviar ao Roku**, que usa essa rota. Isso não transcodifica e
não cria um MP4: envia a URL do manifesto ao player nativo do Roku.

Gerar um MP4 real a partir de HLS exigiria baixar/remuxar todos os segmentos
(ou usar FFmpeg, uma dependência nativa grande). Isso foi **deliberadamente
evitado** neste protótipo: violaria a restrição de não baixar o vídeo inteiro
antes de reproduzir e não é necessário para o Roku, que aceita HLS direto.

### Lista de episódios / arquivos (não implementado)

O Roku Media Player aceita playlists `.M3U`/`.M3U8`, então é tecnicamente
possível publicar um item `playlist.m3u8` no `ContentDirectory`. Hoje o servidor
publica apenas **um** item virtual, porque o `CastProxyServer` é um singleton
com uma única fonte por vez. Para uma lista real de episódios seria necessário
estender o proxy para multiple sources (`/video?id=...`), resolver as URLs de
cada episódio pelo extension ativo e gerar os `<res>` correspondentes. Isto
fica como próxima fase, para não modificar o Cast existente sem validação.

### Erro `no valid bitrates` (-5)

O Roku encontra e lista o servidor, mas ao iniciar informa `no valid bitrates`
quando não consegue montar as *stream qualities* do `Video` node. Isso é um
detalhe de metadados do `res`, não de descoberta SSDP nem necessariamente do
container do arquivo. A correção acima envia `bitrate`, `size` e `duration`
reais e duas variantes de `protocolInfo`. Se a fonte for HLS, o erro também
pode ocorrer quando o manifesto mestre não traz `BANDWIDTH` válido nos
`#EXT-X-STREAM-INF`; nesse caso teste primeiro um episódio MP4/MKV progressivo.

## Limitações conhecidas

- O servidor vive no isolate da app. Se o Android suspender ou matar o
  processo (app em segundo plano por muito tempo, tela desligada, bateria),
  o servidor some. Não há foreground service dedicado nesta fase.
- Sem `CHANGE_WIFI_MULTICAST_STATE`/multicast lock nativo, a recepção de
  `M-SEARCH` pode falhar com a tela desligada. Os `NOTIFY` periódicos
  normalmente bastam com a app em primeiro plano.
- HLS é repassado como `application/vnd.apple.mpegurl` e DASH como
  `application/dash+xml` (sem transcodificação). O Roku Media Player pode não
  listar/reproduzir esses formatos via navegação DLNA; MP4/MKV progressivo é o
  caminho validado primeiro.
- Fontes com URLs temporárias/headers são suportadas enquanto o proxy estiver
  ativo; se o token expirar durante a reprodução na TV, será necessário
  reiniciar o servidor.
- Busca (`Search`) no ContentDirectory e eventos (`eventSub`) são stubs; apenas
  `Browse` é funcional.
- O servidor escuta em todas as interfaces da rede local e não exige
  autenticação. Use apenas em uma rede confiável.
- Não há sincronização de posição: a TV começa do início do arquivo virtual,
  mesmo que o player do Android estivesse em outro ponto.
- Cast para dispositivo e servidor local são mutuamente exclusivos (ambos usam
  o mesmo `CastProxyServer`); o painel bloqueia um enquanto o outro está ativo.
