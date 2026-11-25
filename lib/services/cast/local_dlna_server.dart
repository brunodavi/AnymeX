import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import 'cast_proxy_server.dart';

/// The currently playing source as exposed by the local DLNA server.
class LocalDlnaSource {
  final String url;
  final Map<String, String>? headers;
  final String title;
  final String? subtitleUrl;
  final String mimeType;

  const LocalDlnaSource({
    required this.url,
    required this.title,
    required this.mimeType,
    this.headers,
    this.subtitleUrl,
  });

  /// Detects the real MIME type without downloading the media.
  ///
  /// The extension is trusted first. When there is no useful extension we do
  /// a single HTTP HEAD (with the original playback headers) and fall back to
  /// `application/octet-stream` so we never advertise a format we did not
  /// confirm.
  static Future<LocalDlnaSource> fromPlayback({
    required String url,
    required String title,
    Map<String, String>? headers,
    String? subtitleUrl,
  }) async {
    final mime = await detectMimeType(url, headers);
    return LocalDlnaSource(
      url: url,
      title: title,
      headers: headers,
      subtitleUrl: subtitleUrl,
      mimeType: mime,
    );
  }

  static Future<String> detectMimeType(
    String url,
    Map<String, String>? headers,
  ) async {
    final clean = url.split('?').first.toLowerCase();
    if (clean.endsWith('.m3u8')) return 'application/vnd.apple.mpegurl';
    if (clean.endsWith('.mpd')) return 'application/dash+xml';

    final byExtension = _mimeFromPath(clean);
    if (byExtension != null) return byExtension;
    if (url.startsWith('/') || url.startsWith('file://')) {
      return 'application/octet-stream';
    }

    try {
      final request = http.Request('HEAD', Uri.parse(url));
      if (headers != null) request.headers.addAll(headers);
      final response = await request
          .send()
          .timeout(const Duration(seconds: 3));
      final contentType = response.headers['content-type'];
      if (contentType != null && contentType.trim().isNotEmpty) {
        return contentType.split(';').first.trim().toLowerCase();
      }
    } catch (_) {}

    return 'application/octet-stream';
  }

  static String? _mimeFromPath(String lowerPath) {
    if (lowerPath.endsWith('.mp4')) return 'video/mp4';
    if (lowerPath.endsWith('.m4v')) return 'video/x-m4v';
    if (lowerPath.endsWith('.mkv')) return 'video/x-matroska';
    if (lowerPath.endsWith('.webm')) return 'video/webm';
    if (lowerPath.endsWith('.mov')) return 'video/quicktime';
    return null;
  }
}

/// Minimal UPnP/DLNA MediaServer that publishes the current AnymeX video.
///
/// This is intentionally isolated from [CastService]: it reuses the existing
/// [CastProxyServer] for HTTP Range/header handling and adds only the UPnP
/// discovery + ContentDirectory glue needed by clients such as Roku Media
/// Player. No transcoding and no full download are performed.
class LocalDlnaServer {
  static final LocalDlnaServer instance = LocalDlnaServer._();
  LocalDlnaServer._();

  static const String _udn = 'anymex-local-dlna-1';
  static const String _uuid = 'uuid:$_udn';
  static const String _deviceType = 'urn:schemas-upnp-org:device:MediaServer:1';
  static const String _contentDirectoryType =
      'urn:schemas-upnp-org:service:ContentDirectory:1';
  static const String _connectionManagerType =
      'urn:schemas-upnp-org:service:ConnectionManager:1';
  static const String _serverName =
      'Android UPnP/1.1 AnymeX Local DLNA Server/1.0';
  static final InternetAddress _multicast = InternetAddress('239.255.255.250');

  static const List<String> _targets = <String>[
    'upnp:rootdevice',
    _uuid,
    _deviceType,
    _contentDirectoryType,
    _connectionManagerType,
  ];

  final RxBool isRunning = false.obs;
  final RxnString proxyUrl = RxnString();
  final RxnString lastError = RxnString();

  LocalDlnaSource? _source;
  HttpServer? _httpServer;
  RawDatagramSocket? _ssdpSocket;
  Timer? _notifyTimer;
  String _host = '127.0.0.1';
  int _port = 0;
  bool _starting = false;

  String get _locationUrl => 'http://$_host:$_port/description.xml';

  Future<bool> start(LocalDlnaSource source) async {
    if (_starting) return false;
    _starting = true;
    try {
      await stop();
      lastError.value = null;

      final proxy = await CastProxyServer.startProxy(
        originalUrl: source.url,
        headers: source.headers,
        subtitleUrl: source.subtitleUrl,
        subtitleLabel: source.title,
      );
      if (proxy == null || CastProxyServer.currentProxyUrl == null) {
        throw SocketException('Could not start the media proxy');
      }

      _source = source;
      proxyUrl.value = proxy;
      _host = Uri.parse(proxy).host;

      _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _httpServer!.port;
      _httpServer!.listen(
        (request) => _handleHttpRequest(request),
        onError: (Object error) {},
      );

      await _bindSsdp();
      _sendAlive();
      _notifyTimer = Timer.periodic(
        const Duration(seconds: 25),
        (_) => _sendAlive(),
      );

      isRunning.value = true;
      return true;
    } catch (error) {
      lastError.value = error.toString();
      await stop();
      return false;
    } finally {
      _starting = false;
    }
  }

  /// Keeps the virtual file in sync with the episode/track selected in the
  /// player. The UPnP announcements are refreshed so Roku drops the old URL.
  Future<void> updateSource(LocalDlnaSource source) async {
    if (!isRunning.value) return;
    _source = source;

    final proxy = await CastProxyServer.startProxy(
      originalUrl: source.url,
      headers: source.headers,
      subtitleUrl: source.subtitleUrl,
      subtitleLabel: source.title,
    );
    if (proxy != null && CastProxyServer.currentProxyUrl != null) {
      proxyUrl.value = proxy;
      _host = Uri.parse(proxy).host;
      _sendAlive();
    }
  }

  Future<void> stop() async {
    if (isRunning.value) _sendByeBye();

    _notifyTimer?.cancel();
    _notifyTimer = null;
    _ssdpSocket?.close();
    _ssdpSocket = null;
    await _httpServer?.close(force: true);
    _httpServer = null;
    await CastProxyServer.stopProxy();

    _source = null;
    isRunning.value = false;
    proxyUrl.value = null;
  }

  Future<void> _bindSsdp() async {
    try {
      _ssdpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        1900,
        reuseAddress: true,
        reusePort: true,
        ttl: 4,
      );
    } catch (_) {
      // Port 1900 may already be used. Clients usually accept responses from
      // an ephemeral source port; NOTIFY still makes the server discoverable.
      _ssdpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
        ttl: 4,
      );
    }

    _ssdpSocket!.broadcastEnabled = true;
    try {
      _ssdpSocket!.joinMulticast(_multicast);
    } catch (_) {}
    _ssdpSocket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _ssdpSocket?.receive();
      if (datagram == null) return;
      if (datagram.address.address == _host) return;

      final message = String.fromCharCodes(datagram.data);
      if (!message.toUpperCase().startsWith('M-SEARCH')) return;

      final st = _header(message, 'ST') ?? 'upnp:rootdevice';
      for (final target in _targets) {
        if (_matches(target, st)) {
          _sendSearchResponse(datagram.address, datagram.port, target);
        }
      }
    });
  }

  bool _matches(String target, String st) {
    final search = st.toLowerCase();
    if (search == 'ssdp:all') return true;
    if (search == target.toLowerCase()) return true;
    if (search == _uuid.toLowerCase()) return target == _uuid;
    if (search.contains('mediaserver')) return target == _deviceType;
    if (search.contains('contentdirectory')) return target == _contentDirectoryType;
    if (search.contains('connectionmanager')) {
      return target == _connectionManagerType;
    }
    return false;
  }

  String _usnFor(String target) =>
      target == _uuid ? _uuid : '$_uuid::$target';

  String _header(String message, String name) {
    final match = RegExp(
      '^${name}:\\s*(.*)\$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(message);
    return match?.group(1)?.trim() ?? '';
  }

  void _sendSearchResponse(InternetAddress address, int port, String target) {
    final message = <String>[
      'HTTP/1.1 200 OK',
      'CACHE-CONTROL: max-age=60',
      'EXT:',
      'LOCATION: $_locationUrl',
      'SERVER: $_serverName',
      'ST: $target',
      'USN: ${_usnFor(target)}',
      'BOOTID.UPNP.ORG: 1',
      'CONFIGID.UPNP.ORG: 0',
      '',
      '',
    ].join('\r\n');
    _ssdpSocket?.send(utf8.encode(message), address, port);
  }

  void _sendAlive() {
    if (_ssdpSocket == null) return;
    for (final target in _targets) {
      final message = <String>[
        'NOTIFY * HTTP/1.1',
        'HOST: 239.255.255.250:1900',
        'CACHE-CONTROL: max-age=60',
        'LOCATION: $_locationUrl',
        'NT: $target',
        'NTS: ssdp:alive',
        'SERVER: $_serverName',
        'USN: ${_usnFor(target)}',
        'BOOTID.UPNP.ORG: 1',
        'CONFIGID.UPNP.ORG: 0',
        '',
        '',
      ].join('\r\n');
      _ssdpSocket!.send(utf8.encode(message), _multicast, 1900);
    }
  }

  void _sendByeBye() {
    if (_ssdpSocket == null) return;
    for (final target in _targets) {
      final message = <String>[
        'NOTIFY * HTTP/1.1',
        'HOST: 239.255.255.250:1900',
        'NT: $target',
        'NTS: ssdp:byebye',
        'USN: ${_usnFor(target)}',
        '',
        '',
      ].join('\r\n');
      _ssdpSocket!.send(utf8.encode(message), _multicast, 1900);
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/description.xml') {
        _reply(request, _descriptionXml(), contentType: 'text/xml');
        return;
      }
      if (path == '/ContentDirectory.xml') {
        _reply(request, _contentDirectoryScpd(), contentType: 'text/xml');
        return;
      }
      if (path == '/ConnectionManager.xml') {
        _reply(request, _connectionManagerScpd(), contentType: 'text/xml');
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      if (path == '/control/ContentDirectory') {
        final action = _soapAction(body);
        String responseBody;
        switch (action) {
          case 'Browse':
            responseBody = _browseResponse(body);
            break;
          case 'GetSystemUpdateID':
            responseBody = _soapResponse(
              '<u:GetSystemUpdateIDResponse '
              'xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
              '<Id>1</Id></u:GetSystemUpdateIDResponse>',
            );
            break;
          case 'GetSearchCapabilities':
            responseBody = _soapResponse(
              '<u:GetSearchCapabilitiesResponse '
              'xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
              '<SearchCaps></SearchCaps></u:GetSearchCapabilitiesResponse>',
            );
            break;
          case 'GetSortCapabilities':
            responseBody = _soapResponse(
              '<u:GetSortCapabilitiesResponse '
              'xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
              '<SortCaps></SortCaps></u:GetSortCapabilitiesResponse>',
            );
            break;
          default:
            request.response.statusCode = HttpStatus.internalServerError;
            _reply(request, _soapFault(action),
                contentType: 'text/xml', alreadySending: true);
            return;
        }
        _reply(request, responseBody, contentType: 'text/xml');
        return;
      }

      if (path == '/control/ConnectionManager') {
        final action = _soapAction(body);
        final responseBody = action == 'GetProtocolInfo'
            ? _soapResponse(
                '<u:GetProtocolInfoResponse '
                'xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">'
                '<Source>http-get:*:video/mp4:*,'
                'http-get:*:video/x-matroska:*,'
                'http-get:*:application/vnd.apple.mpegurl:*</Source>'
                '<Sink></Sink></u:GetProtocolInfoResponse>',
              )
            : _soapFault(action);
        _reply(request, responseBody, contentType: 'text/xml');
        return;
      }

      // Event subscriptions are accepted but no events are sent in the
      // prototype. Most renderers do not require them for Browse playback.
      if (path.startsWith('/events/')) {
        request.response.headers.set('TIMEOUT', 'Second-1800');
        _reply(request, '', contentType: 'text/xml');
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  void _reply(
    HttpRequest request,
    String body, {
    required String contentType,
    bool alreadySending = false,
  }) {
    if (!alreadySending) {
      request.response.headers.contentType = ContentType.parse(contentType);
    }
    request.response.write(body);
    request.response.close();
  }

  String _soapAction(String body) =>
      RegExp(r'<(?:[A-Za-z]+:)?(Browse|GetSystemUpdateID|'
              r'GetSearchCapabilities|GetSortCapabilities|GetProtocolInfo|'
              r'Search)\b')
          .firstMatch(body)
          ?.group(1) ??
      '';

  String _tag(String body, String name) => RegExp(
        '<(?:[A-Za-z]+:)?$name>(.*?)</(?:[A-Za-z]+:)?$name>',
        dotAll: true,
      ).firstMatch(body)?.group(1)?.trim() ??
      '';

  String _soapResponse(String actionResponse) =>
      '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope '
      'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body>$actionResponse</s:Body></s:Envelope>';

  String _soapFault(String action) => _soapResponse(
        '<s:Fault><faultcode>s:Client</faultcode>'
        '<faultstring>UPnPError</faultstring><detail>'
        '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
        '<errorCode>401</errorCode><errorDescription>Invalid Action: '
        '${_escape(action)}</errorDescription></UPnPError>'
        '</detail></s:Fault>',
      );

  String _browseResponse(String body) {
    final objectId = _tag(body, 'ObjectID').isEmpty
        ? '0'
        : _tag(body, 'ObjectID');
    final browseFlag = _tag(body, 'BrowseFlag').isEmpty
        ? 'BrowseDirectChildren'
        : _tag(body, 'BrowseFlag');
    final didl = _didl(objectId, browseFlag);
    final count = RegExp(r'<item\b').allMatches(didl).length +
        RegExp(r'<container\b').allMatches(didl).length;

    return _soapResponse(
      '<u:BrowseResponse '
      'xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
      '<Result>${_escape(didl)}</Result>'
      '<NumberReturned>$count</NumberReturned>'
      '<TotalMatches>$count</TotalMatches>'
      '<UpdateID>1</UpdateID>'
      '</u:BrowseResponse>',
    );
  }

  String _didl(String objectId, String browseFlag) {
    final source = _source;
    final mediaUrl = CastProxyServer.currentProxyUrl ?? proxyUrl.value ?? '';
    final mime = source?.mimeType ?? 'application/octet-stream';
    final title = _escape(source?.title ?? 'AnymeX Video');

    final caption = CastProxyServer.currentSubtitleUrl == null
        ? ''
        : '<sec:CaptionInfoEx xmlns:sec="http://www.sec.co.kr/" '
          'sec:type="vtt">${_escape(CastProxyServer.currentSubtitleUrl!)}'
          '</sec:CaptionInfoEx>';

    final item = '<item id="video" parentID="videos" restricted="1">'
        '<dc:title>$title</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:$mime:*">${_escape(mediaUrl)}</res>'
        '$caption'
        '</item>';

    final videosContainer =
        '<container id="videos" parentID="0" restricted="1">'
        '<dc:title>Videos</dc:title>'
        '<upnp:class>object.container.storageFolder</upnp:class>'
        '</container>';

    final rootContainer = '<container id="0" parentID="-1" restricted="1">'
        '<dc:title>AnymeX</dc:title>'
        '<upnp:class>object.container</upnp:class>'
        '</container>';

    final children = objectId == '0'
        ? '$videosContainer$item'
        : objectId == 'videos'
            ? item
            : '';

    final content = browseFlag == 'BrowseMetadata' && objectId == '0'
        ? rootContainer
        : browseFlag == 'BrowseMetadata' && objectId == 'videos'
            ? videosContainer
            : browseFlag == 'BrowseMetadata' && objectId == 'video'
                ? item
                : children;

    return '<DIDL-Lite '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
        '$content</DIDL-Lite>';
  }

  String _descriptionXml() => '<?xml version="1.0" encoding="utf-8"?>'
      '<root xmlns="urn:schemas-upnp-org:device-1-0">'
      '<specVersion><major>1</major><minor>0</minor></specVersion>'
      '<URLBase>http://$_host:$_port/</URLBase>'
      '<device>'
      '<deviceType>$_deviceType</deviceType>'
      '<friendlyName>AnymeX (Servidor DLNA local)</friendlyName>'
      '<manufacturer>AnymeX</manufacturer>'
      '<modelName>AnymeX Local DLNA</modelName>'
      '<modelNumber>1</modelNumber>'
      '<serialNumber>1</serialNumber>'
      '<UDN>$_uuid</UDN>'
      '<dlna:X_DLNADOC xmlns:dlna="urn:schemas-dlna-org:device-1-0">'
      'DMS-1.50</dlna:X_DLNADOC>'
      '<serviceList>'
      '<service>'
      '<serviceType>$_contentDirectoryType</serviceType>'
      '<serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>'
      '<SCPDURL>/ContentDirectory.xml</SCPDURL>'
      '<controlURL>/control/ContentDirectory</controlURL>'
      '<eventSubURL>/events/ContentDirectory</eventSubURL>'
      '</service>'
      '<service>'
      '<serviceType>$_connectionManagerType</serviceType>'
      '<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>'
      '<SCPDURL>/ConnectionManager.xml</SCPDURL>'
      '<controlURL>/control/ConnectionManager</controlURL>'
      '<eventSubURL>/events/ConnectionManager</eventSubURL>'
      '</service>'
      '</serviceList>'
      '</device>'
      '</root>';

  String _contentDirectoryScpd() => '<?xml version="1.0" encoding="utf-8"?>'
      '<scpd xmlns="urn:schemas-upnp-org:service-1-0">'
      '<specVersion><major>1</major><minor>0</minor></specVersion>'
      '<actionList>'
      '<action><name>Browse</name><argumentList>'
      '<argument><name>ObjectID</name><direction>in</direction>'
      '<relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument>'
      '<argument><name>BrowseFlag</name><direction>in</direction>'
      '<relatedStateVariable>A_ARG_TYPE_BrowseFlag</relatedStateVariable></argument>'
      '<argument><name>Filter</name><direction>in</direction>'
      '<relatedStateVariable>A_ARG_TYPE_Filter</relatedStateVariable></argument>'
      '<argument><name>StartingIndex</name><direction>in</direction>'
      '<relatedStateVariable>A_ARG_TYPE_Index</relatedStateVariable></argument>'
      '<argument><name>RequestedCount</name><direction>in</direction>'
      '<relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument>'
      '<argument><name>SortCriteria</name><direction>in</direction>'
      '<relatedStateVariable>A_ARG_TYPE_SortCriteria</relatedStateVariable></argument>'
      '<argument><name>Result</name><direction>out</direction>'
      '<relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument>'
      '<argument><name>NumberReturned</name><direction>out</direction>'
      '<relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument>'
      '<argument><name>TotalMatches</name><direction>out</direction>'
      '<relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument>'
      '<argument><name>UpdateID</name><direction>out</direction>'
      '<relatedStateVariable>A_ARG_TYPE_UpdateID</relatedStateVariable></argument>'
      '</argumentList></action>'
      '<action><name>GetSystemUpdateID</name><argumentList>'
      '<argument><name>Id</name><direction>out</direction>'
      '<relatedStateVariable>A_ARG_TYPE_UpdateID</relatedStateVariable></argument>'
      '</argumentList></action>'
      '<action><name>GetSearchCapabilities</name><argumentList>'
      '<argument><name>SearchCaps</name><direction>out</direction>'
      '<relatedStateVariable>SearchCaps</relatedStateVariable></argument>'
      '</argumentList></action>'
      '<action><name>GetSortCapabilities</name><argumentList>'
      '<argument><name>SortCaps</name><direction>out</direction>'
      '<relatedStateVariable>SortCaps</relatedStateVariable></argument>'
      '</argumentList></action>'
      '</actionList>'
      '<serviceStateTable>'
      '<stateVariable sendEvents="no"><name>A_ARG_TYPE_ObjectID</name>'
      '<dataType>string</dataType></stateVariable>'
      '<stateVariable sendEvents="no"><name>A_ARG_TYPE_BrowseFlag</name>'
      '<dataType>string</dataType><allowedValueList>'
      '<allowedValue>BrowseMetadata</allowedValue>'
      '<allowedValue>BrowseDirectChildren</allowedValue>'
      '</allowedValueList></stateVariable>'
      '<stateVariable sendEvents="no"><name>A_ARG_TYPE_Filter</name>'
      '<dataType>string</dataType></stateVariable>'
      '<stateVariable sendEvents="no"><name>A_ARG_TYPE_SortCriteria</name>'
      '<dataType>string</dataType></stateVariable>'
      '<stateVariable sendEvents="no"><name>A_ARG_TYPE_Result</name>'
      '<dataType>string</dataType></stateVariable>'
      '<stateVariable sendEvents="no"><name>A_ARG_TYPE_Index</name>'
      '<dataType>ui4</dataType></stateVariable>'
      '<stateVariable sendEvents="no"><name>A_ARG_TYPE_Count</name>'
      '<dataType>ui4</dataType></stateVariable>'
      '<stateVariable sendEvents="no"><name>A_ARG_TYPE_UpdateID</name>'
      '<dataType>ui4</dataType></stateVariable>'
      '<stateVariable sendEvents="no"><name>SearchCaps</name>'
      '<dataType>string</dataType></stateVariable>'
      '<stateVariable sendEvents="no"><name>SortCaps</name>'
      '<dataType>string</dataType></stateVariable>'
      '</serviceStateTable>'
      '</scpd>';

  String _connectionManagerScpd() => '<?xml version="1.0" encoding="utf-8"?>'
      '<scpd xmlns="urn:schemas-upnp-org:service-1-0">'
      '<specVersion><major>1</major><minor>0</minor></specVersion>'
      '<actionList>'
      '<action><name>GetProtocolInfo</name><argumentList>'
      '<argument><name>Source</name><direction>out</direction>'
      '<relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument>'
      '<argument><name>Sink</name><direction>out</direction>'
      '<relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument>'
      '</argumentList></action>'
      '</actionList>'
      '<serviceStateTable>'
      '<stateVariable sendEvents="yes"><name>SourceProtocolInfo</name>'
      '<dataType>string</dataType></stateVariable>'
      '<stateVariable sendEvents="yes"><name>SinkProtocolInfo</name>'
      '<dataType>string</dataType></stateVariable>'
      '</serviceStateTable>'
      '</scpd>';

  String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
