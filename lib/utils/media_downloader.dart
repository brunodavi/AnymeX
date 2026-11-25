import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:typed_data';
import 'package:anymex_extension_runtime_bridge/Models/Source.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:anymex/database/isar_models/track.dart' as hive;
import 'package:anymex/utils/download_isolate_pool.dart';
import 'package:anymex/utils/logger.dart';

class HlsSegmentKey {
  final String method;
  final String? uri;
  final Uint8List? keyBytes;
  final Uint8List? iv;

  const HlsSegmentKey({
    required this.method,
    this.uri,
    this.keyBytes,
    this.iv,
  });
}

class _HlsSegment {
  final String url;
  final HlsSegmentKey key;
  const _HlsSegment({required this.url, required this.key});
}

class _AudioInput {
  final String path;
  final String label;
  final String language;

  const _AudioInput({
    required this.path,
    required this.label,
    required this.language,
  });
}

class _SubtitleInput {
  final String path;
  final String label;
  final String codec;

  const _SubtitleInput({
    required this.path,
    required this.label,
    required this.codec,
  });
}

/// Resultado final de um download.
///
/// Quando [tracksMuxed] é true o arquivo [filePath] é um MKV com todas as
/// faixas de audio/legenda embutidas (selecionáveis no player). Se o FFmpeg
/// falhar, o video HLS bruto é mantido e as faixas ficam como arquivos
/// separados, registrados em `audios`/`subtitles` da tarefa.
class MediaDownloadResult {
  final String filePath;
  final bool tracksMuxed;

  /// Faixas de audio locais, usadas apenas quando o mux falha e o player
  /// precisa carrega-las como faixas externas.
  final List<hive.Track>? audioTracks;

  const MediaDownloadResult({
    required this.filePath,
    required this.tracksMuxed,
    this.audioTracks,
  });
}

class MediaDownloader {
  final String taskId;
  final ItemType itemType;
  final List<PageUrl>? pageUrls;
  final int concurrentDownloads;
  final List<hive.Track>? subtitles;
  final List<hive.Track>? audios;
  final String? subDownloadDir;
  final String? m3u8Url;
  final String? videoFileName;
  final Map<String, String>? headers;
  final String? episodeNumber;

  final List<String> _auxTaskIds = <String>[];
  int? _ffmpegSessionId;

  static var httpClient = http.Client();

  MediaDownloader({
    required this.taskId,
    required this.itemType,
    this.pageUrls,
    this.subtitles,
    this.audios,
    this.subDownloadDir,
    this.m3u8Url,
    this.videoFileName,
    this.headers,
    this.concurrentDownloads = 1,
    this.episodeNumber,
  });

  static Future<void> initializeIsolatePool({int poolSize = 6}) async {
    DownloadIsolatePool.configure(poolSize: poolSize);
    await DownloadIsolatePool.instance.initialize();
  }

  void close() {
    DownloadIsolatePool.instance.cancelTask(taskId);
    for (final id in _auxTaskIds.toList()) {
      DownloadIsolatePool.instance.cancelTask(id);
    }
    final sessionId = _ffmpegSessionId;
    if (sessionId != null) {
      FFmpegKit.cancel(sessionId);
    }
    if (subDownloadDir != null) {
      try {
        final tempDir = Directory(path.join(subDownloadDir!, 'temp_$taskId'));
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }

  static Future<T> _withRetryStatic<T>(
    Future<T> Function() operation,
    int maxRetries,
  ) async {
    int attempts = 0;
    while (true) {
      try {
        attempts++;
        return await operation();
      } catch (e) {
        if (attempts >= maxRetries) {
          throw MediaDownloaderException(
            'Operation failed after $maxRetries attempts',
            e,
          );
        }
        await Future.delayed(
            Duration(milliseconds: 500 * (1 << (attempts - 1))));
      }
    }
  }

  static String getSubtitleExtension(String url) {
    final lower = url.toLowerCase().split('?').first;
    for (final ext in ['.vtt', '.srt', '.ass', '.ssa']) {
      if (lower.endsWith(ext)) return ext;
    }
    return '.srt';
  }

  static String _audioExtension(String url) {
    final lower = url.toLowerCase().split('?').first;
    for (final ext in ['.m4a', '.aac', '.mp3', '.ogg', '.opus', '.wav', '.flac', '.ts']) {
      if (lower.endsWith(ext)) return ext;
    }
    return '.m4a';
  }

  static String _languageCode(String label) {
    final lower = label.toLowerCase();
    if (lower.contains('portugu') || lower.contains('pt-br') || lower == 'pt') {
      return 'pt-BR';
    }
    if (lower.contains('japon') || lower.contains('japanese') || lower.contains(' jp')) {
      return 'ja';
    }
    if (lower.contains('ingl') || lower.contains('english')) return 'en';
    if (lower.contains('corean') || lower.contains('korean')) return 'ko';
    if (lower.contains('espan') || lower.contains('spanish')) return 'es';
    final cleaned = label.replaceAll(RegExp(r'[^A-Za-z]'), '').toLowerCase();
    return cleaned.isEmpty ? 'und' : cleaned;
  }

  static String _changeExtension(String filePath, String extension) {
    final ext = path.extension(filePath);
    return ext.isEmpty
        ? '$filePath$extension'
        : '${filePath.substring(0, filePath.length - ext.length)}$extension';
  }

  Future<MediaDownloadResult> download(
      void Function(DownloadProgress) onProgress) async {
    final isHls = itemType == ItemType.anime &&
        m3u8Url != null &&
        videoFileName != null &&
        subDownloadDir != null;

    try {
      if (isHls) {
        await _downloadM3u8WithProgress(onProgress);
      } else if (pageUrls != null) {
        await _downloadFilesWithProgress(pageUrls!, onProgress);
      }

      final subtitleInputs = isHls ? await _downloadSubtitleFiles() : <_SubtitleInput>[];
      final audioInputs = isHls ? await _downloadAudioFiles() : <_AudioInput>[];

      if (isHls) {
        return await _finalizeHlsDownload(audioInputs, subtitleInputs);
      }

      final directPath = (pageUrls != null && pageUrls!.isNotEmpty)
          ? pageUrls!.first.fileName ?? ''
          : '';
      return MediaDownloadResult(filePath: directPath, tracksMuxed: false);
    } catch (e) {
      throw MediaDownloaderException('Download failed', e);
    } finally {
      close();
    }
  }

  Future<void> _downloadFilesWithProgress(
    List<PageUrl> pageUrls,
    void Function(DownloadProgress) onProgress,
  ) async {
    final completer = Completer<void>();

    await DownloadIsolatePool.instance.submitFileDownload(
      taskId: taskId,
      pageUrls: pageUrls,
      concurrentDownloads: concurrentDownloads,
      itemType: itemType,
      onProgress: (progress) {
        onProgress(progress);
      },
      onComplete: () {
        onProgress(
          DownloadProgress(1, 1, itemType, isCompleted: true),
        );
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );

    return completer.future;
  }

  Future<void> _downloadM3u8WithProgress(
      void Function(DownloadProgress) onProgress) async {
    final completer = Completer<void>();

    final rootBody = await _fetchText(m3u8Url!, headers);
    String mediaM3u8Url = m3u8Url!;
    String mediaBody = rootBody;

    if (_isMasterPlaylist(rootBody)) {
      mediaM3u8Url = _resolveBestVariant(rootBody, m3u8Url!, null);
      mediaBody = await _fetchText(mediaM3u8Url, headers);
    }

    final segments =
        await _parseMediaPlaylist(mediaBody, mediaM3u8Url, headers);
    if (segments.isEmpty) {
      throw Exception('No segments found');
    }
    final mediaSequence = _extractMediaSequence(mediaBody) ?? 0;

    final tsInfos = <TsInfo>[];
    for (int i = 0; i < segments.length; i++) {
      tsInfos.add(TsInfo(url: segments[i].url, name: 'TS_${i + 1}'));
    }

    final mediaDir = Directory(subDownloadDir!);
    await mediaDir.create(recursive: true);
    final tempDir = path.join(subDownloadDir!, 'temp_$taskId');
    await Directory(tempDir).create(recursive: true);
    await File(path.join(tempDir, '.nomedia')).create();

    Uint8List? globalKey;
    Uint8List? globalIv;
    final firstWithKey = _findFirstWithKey(segments);
    if (firstWithKey != null) {
      globalKey = firstWithKey.key.keyBytes;
      globalIv = firstWithKey.key.iv;
    }

    final pendingSegments = tsInfos
        .where((ts) => !File(path.join(tempDir, '${ts.name}.ts')).existsSync())
        .toList();

    await DownloadIsolatePool.instance.submitM3u8Download(
      taskId: taskId,
      segments: pendingSegments,
      tempDir: tempDir,
      key: globalKey,
      iv: globalIv,
      mediaSequence: mediaSequence,
      concurrentDownloads: concurrentDownloads,
      headers: headers,
      itemType: itemType,
      onProgress: (progress) {
        onProgress(progress);
      },
      onComplete: () async {
        try {
          await _mergeTsToFile(
            path.join(tempDir, 'video.ts'),
            tempDir,
          );
          onProgress(DownloadProgress(1, 1, itemType, isCompleted: true));
          if (!completer.isCompleted) completer.complete();
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      onError: (error) {
        if (subDownloadDir != null) {
          try {
            final tempDir =
                Directory(path.join(subDownloadDir!, 'temp_$taskId'));
            if (tempDir.existsSync()) {
              tempDir.deleteSync(recursive: true);
            }
          } catch (_) {}
        }
        if (!completer.isCompleted) completer.completeError(error);
      },
    );

    return completer.future;
  }

  Future<List<_SubtitleInput>> _downloadSubtitleFiles() async {
    final inputs = <_SubtitleInput>[];
    if (episodeNumber == null || subDownloadDir == null) return inputs;

    final subFolder =
        path.join(subDownloadDir!, 'Episode_${episodeNumber}_subs');
    for (final element in subtitles ?? <hive.Track>[]) {
      final url = element.file;
      if (url == null || url.isEmpty) continue;

      final ext = getSubtitleExtension(url);
      final safeName = sanitizePathSegment('${element.label}$ext');
      final subtitleFile = File(path.join(subFolder, safeName));
      if (!subtitleFile.existsSync() || subtitleFile.lengthSync() == 0) {
        try {
          final response = await _withRetryStatic(
            () => httpClient.get(Uri.parse(url), headers: headers ?? {}),
            3,
          );
          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            if (!subtitleFile.parent.existsSync()) {
              subtitleFile.parent.createSync(recursive: true);
            }
            await subtitleFile.writeAsBytes(response.bodyBytes);
          }
        } catch (_) {}
      }
      if (subtitleFile.existsSync() && subtitleFile.lengthSync() > 0) {
        final lower = path.extension(subtitleFile.path).toLowerCase();
        inputs.add(_SubtitleInput(
          path: subtitleFile.path,
          label: element.label?.trim().isNotEmpty == true
              ? element.label!.trim()
              : 'Subtitle ${inputs.length + 1}',
          codec: (lower == '.ass' || lower == '.ssa') ? 'ass' : 'srt',
        ));
      }
    }
    return inputs;
  }

  Future<List<_AudioInput>> _downloadAudioFiles() async {
    final inputs = <_AudioInput>[];
    final tracks = audios ?? <hive.Track>[];
    if (tracks.isEmpty || subDownloadDir == null) return inputs;

    final outDir =
        Directory(path.join(subDownloadDir!, 'temp_$taskId', 'audio'));
    await outDir.create(recursive: true);

    for (var i = 0; i < tracks.length; i++) {
      final url = tracks[i].file;
      if (url == null || url.trim().isEmpty) continue;

      final label = tracks[i].label?.trim().isNotEmpty == true
          ? tracks[i].label!.trim()
          : 'Audio ${i + 1}';
      final outPath = path.join(outDir.path, 'audio_${i + 1}${_audioExtension(url)}');
      final audioTaskId = '${taskId}_audio_$i';
      _auxTaskIds.add(audioTaskId);

      try {
        if (url.toLowerCase().contains('.m3u8')) {
          await _downloadHlsAudio(url, outPath, audioTaskId, i);
        } else {
          await _downloadDirectAudio(url, outPath, audioTaskId);
        }
        final file = File(outPath);
        if (file.existsSync() && file.lengthSync() > 0) {
          inputs.add(_AudioInput(
            path: outPath,
            label: label,
            language: _languageCode(label),
          ));
        }
      } catch (e) {
        Logger.e('[Download] Falha ao baixar faixa de audio "$label": $e');
      }
    }
    return inputs;
  }

  Future<void> _downloadDirectAudio(
      String url, String outPath, String audioTaskId) async {
    final completer = Completer<void>();
    await DownloadIsolatePool.instance.submitFileDownload(
      taskId: audioTaskId,
      pageUrls: [
        PageUrl(url: url, headers: headers, fileName: outPath),
      ],
      concurrentDownloads: 1,
      itemType: itemType,
      onProgress: (_) {},
      onComplete: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    return completer.future;
  }

  Future<void> _downloadHlsAudio(
    String url,
    String outPath,
    String audioTaskId,
    int index,
  ) async {
    final rootBody = await _fetchText(url, headers);
    String mediaUrl = url;
    String mediaBody = rootBody;

    if (_isMasterPlaylist(rootBody)) {
      mediaUrl = _resolveAudioRendition(rootBody, url) ??
          _resolveBestVariant(rootBody, url, null);
      mediaBody = await _fetchText(mediaUrl, headers);
    }

    final segments = await _parseMediaPlaylist(mediaBody, mediaUrl, headers);
    if (segments.isEmpty) {
      throw Exception('No audio segments found');
    }

    final audioTempDir = path.join(path.dirname(outPath), 'hls_$index');
    await Directory(audioTempDir).create(recursive: true);
    await File(path.join(audioTempDir, '.nomedia')).create();

    final tsInfos = <TsInfo>[
      for (var i = 0; i < segments.length; i++)
        TsInfo(url: segments[i].url, name: 'TS_${i + 1}'),
    ];
    final firstWithKey = _findFirstWithKey(segments);

    final completer = Completer<void>();
    await DownloadIsolatePool.instance.submitM3u8Download(
      taskId: audioTaskId,
      segments: tsInfos,
      tempDir: audioTempDir,
      key: firstWithKey?.key.keyBytes,
      iv: firstWithKey?.key.iv,
      mediaSequence: _extractMediaSequence(mediaBody) ?? 0,
      concurrentDownloads: concurrentDownloads,
      headers: headers,
      itemType: itemType,
      onProgress: (_) {},
      onComplete: () async {
        try {
          await _mergeTsToFile(outPath, audioTempDir);
          if (!completer.isCompleted) completer.complete();
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    return completer.future;
  }

  Future<MediaDownloadResult> _finalizeHlsDownload(
    List<_AudioInput> audios,
    List<_SubtitleInput> subtitles,
  ) async {
    final tempDir = path.join(subDownloadDir!, 'temp_$taskId');
    final videoTs = path.join(tempDir, 'video.ts');
    final mkvPath = path.join(subDownloadDir!, videoFileName!);
    final fallbackTsPath = _changeExtension(mkvPath, '.ts');

    if (!File(videoTs).existsSync()) {
      throw Exception('Vídeo HLS não foi finalizado');
    }

    // Preserva também o audio que ja vem dentro da variante HLS (alguns
    // servidores nao usam faixa separada).
    int embeddedAudioCount = 0;
    try {
      final probeSession = await FFprobeKit.getMediaInformation(videoTs);
      final info = probeSession.getMediaInformation();
      embeddedAudioCount = info
              ?.getStreams()
              .where((stream) => stream.getType() == 'audio')
              .length ??
          0;
    } catch (e) {
      Logger.e('[Download] FFprobe nao conseguiu ler as faixas do HLS: $e');
    }

    final args = <String>[
      '-y',
      '-i', videoTs,
      for (final audio in audios) ...['-i', audio.path],
      for (final sub in subtitles) ...['-i', sub.path],
      '-map', '0:v:0',
      '-c:v', 'copy',
      if (embeddedAudioCount > 0) ...['-map', '0:a?'],
      for (var i = 0; i < audios.length; i++) ...['-map', '${i + 1}:a:0?'],
      '-c:a', 'copy',
    ];

    for (var i = 0; i < embeddedAudioCount; i++) {
      args.addAll([
        '-metadata:s:a:$i', 'title=HLS ${i + 1}',
        '-metadata:s:a:$i', 'language=und',
      ]);
      if (i == 0) args.addAll(['-disposition:a:0', 'default']);
    }

    for (var i = 0; i < audios.length; i++) {
      final audio = audios[i];
      final outIndex = embeddedAudioCount + i;
      args.addAll([
        '-metadata:s:a:$outIndex', 'title=${audio.label}',
        '-metadata:s:a:$outIndex', 'language=${audio.language}',
      ]);
      if (embeddedAudioCount == 0 && i == 0) {
        args.addAll(['-disposition:a:0', 'default']);
      }
    }

    final subtitleInputOffset = 1 + audios.length;
    for (var i = 0; i < subtitles.length; i++) {
      final sub = subtitles[i];
      args.addAll([
        '-map', '${subtitleInputOffset + i}:s:0',
        '-c:s:$i', sub.codec,
        '-metadata:s:s:$i', 'title=${sub.label}',
        '-metadata:s:s:$i', 'language=${_languageCode(sub.label)}',
      ]);
      if (i == 0) args.addAll(['-disposition:s:$i', 'default']);
    }

    args.addAll(['-f', 'matroska', mkvPath]);

    try {
      final session = await FFmpegKit.executeWithArguments(args);
      _ffmpegSessionId = session.getSessionId();
      final returnCode = await session.getReturnCode();
      final output = File(mkvPath);
      if (ReturnCode.isSuccess(returnCode) &&
          output.existsSync() &&
          output.lengthSync() > 0) {
        // Faixas embutidas: remove os arquivos separados para o player nao
        // mostrar faixas duplicadas.
        await _cleanupSidecarDirs();
        Logger.i('[Download] Mux concluído: $mkvPath');
        return MediaDownloadResult(filePath: mkvPath, tracksMuxed: true);
      }
      final logs = await session.getLogsAsString();
      Logger.e('[Download] FFmpeg falhou no mux: $logs');
    } catch (e) {
      Logger.e('[Download] FFmpeg indisponível, mantendo faixas separadas: $e');
    }

    await File(videoTs).copy(fallbackTsPath);

    final persistentAudios = <hive.Track>[];
    if (audios.isNotEmpty) {
      final audioDir = Directory(path.join(
          subDownloadDir!, 'Episode_${episodeNumber ?? '0'}_audio'));
      await audioDir.create(recursive: true);
      for (var i = 0; i < audios.length; i++) {
        final audio = audios[i];
        final savedPath = path.join(
            audioDir.path, 'Audio_${i + 1}${path.extension(audio.path)}');
        await File(audio.path).copy(savedPath);
        persistentAudios.add(hive.Track(
          file: Uri.file(savedPath).toString(),
          label: audio.label,
        ));
      }
    }

    return MediaDownloadResult(
      filePath: fallbackTsPath,
      tracksMuxed: false,
      audioTracks: persistentAudios,
    );
  }

  Future<void> _cleanupSidecarDirs() async {
    if (episodeNumber == null || subDownloadDir == null) return;
    for (final name in [
      'Episode_${episodeNumber}_subs',
      'Episode_${episodeNumber}_audio',
    ]) {
      try {
        final dir = Directory(path.join(subDownloadDir!, name));
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<void> _mergeTsToFile(String outputFile, String tempDir) async {
    final dir = Directory(tempDir);
    final files = await dir
        .list()
        .where((entity) =>
            entity.path.endsWith('.ts') &&
            path.normalize(entity.path) != path.normalize(outputFile))
        .toList();

    files.sort((a, b) {
      final aName = path.basenameWithoutExtension(a.path);
      final bName = path.basenameWithoutExtension(b.path);
      final aIndex = int.tryParse(aName.replaceFirst('TS_', '')) ?? 0;
      final bIndex = int.tryParse(bName.replaceFirst('TS_', '')) ?? 0;
      return aIndex.compareTo(bIndex);
    });

    final outFile = File(outputFile);
    await outFile.parent.create(recursive: true);
    final sink = outFile.openWrite();
    try {
      for (final file in files) {
        final rawBytes = await File(file.path).readAsBytes();
        final syncIndex = _findTsSyncByte(rawBytes);
        if (syncIndex > 0) {
          sink.add(rawBytes.sublist(syncIndex));
        } else {
          sink.add(rawBytes);
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  static int _findTsSyncByte(Uint8List bytes) {
    for (int i = 0; i < bytes.length && i < 4096; i++) {
      if (bytes[i] == 0x47) {
        if (i == 0) return 0;
        if (i + 188 < bytes.length && bytes[i + 188] == 0x47) {
          return i;
        }
      }
    }
    return 0;
  }

  static Future<String> _fetchText(
      String url, Map<String, String>? headers) async {
    final response = await http.get(Uri.parse(url), headers: headers ?? {});
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode} fetching $url');
    }
    return response.body;
  }

  static Future<Uint8List> _fetchBytes(
      String url, Map<String, String>? headers) async {
    final response = await http.get(Uri.parse(url), headers: headers ?? {});
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode} fetching $url');
    }
    return response.bodyBytes;
  }

  static bool _isMasterPlaylist(String body) =>
      body.contains('#EXT-X-STREAM-INF') || body.contains('#EXT-X-MEDIA:');

  static String? _resolveAudioRendition(String body, String baseUrl) {
    String? firstUri;
    for (final raw in body.split('\n')) {
      final line = raw.trim();
      if (!line.startsWith('#EXT-X-MEDIA:') ||
          !line.toUpperCase().contains('TYPE=AUDIO')) {
        continue;
      }
      final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);
      if (uriMatch == null) continue;

      final uri = _resolveUrl(uriMatch.group(1)!, baseUrl);
      if (RegExp(r'DEFAULT=YES', caseSensitive: false).hasMatch(line)) {
        return uri;
      }
      firstUri ??= uri;
    }
    return firstUri;
  }

  static String _resolveBestVariant(
      String body, String baseUrl, String? preferred) {
    final lines = body.split('\n').map((l) => l.trim()).toList();
    final variants = <({String uri, int bandwidth, String resolution})>[];

    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
        final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
        final resMatch = RegExp(r'RESOLUTION=([\dx]+)').firstMatch(lines[i]);
        final bandwidth = int.tryParse(bwMatch?.group(1) ?? '0') ?? 0;
        final resolution = resMatch?.group(1) ?? '';
        final uri = i + 1 < lines.length ? lines[i + 1] : '';
        if (uri.isNotEmpty && !uri.startsWith('#')) {
          variants.add((
            uri: _resolveUrl(uri, baseUrl),
            bandwidth: bandwidth,
            resolution: resolution
          ));
        }
      }
    }

    if (variants.isEmpty) return baseUrl;

    if (preferred != null && preferred.isNotEmpty) {
      for (final v in variants) {
        if (v.resolution.contains(preferred) || v.uri.contains(preferred)) {
          return v.uri;
        }
      }
    }

    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return variants.first.uri;
  }

  static _HlsSegment? _findFirstWithKey(List<_HlsSegment> segments) {
    for (final s in segments) {
      if (s.key.method != 'NONE') return s;
    }
    return null;
  }

  static Future<List<_HlsSegment>> _parseMediaPlaylist(
    String body,
    String baseUrl,
    Map<String, String>? headers,
  ) async {
    final lines = body.split('\n').map((l) => l.trim()).toList();
    final segments = <_HlsSegment>[];

    HlsSegmentKey currentKey = const HlsSegmentKey(method: 'NONE');
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.startsWith('#EXT-X-KEY')) {
        currentKey = await _parseKeyTag(line, baseUrl, headers);
        continue;
      }

      if (line.startsWith('#') || line.isEmpty) continue;

      final segUrl = _resolveUrl(line, baseUrl);
      segments.add(_HlsSegment(url: segUrl, key: currentKey));
    }
    return segments;
  }

  static Future<HlsSegmentKey> _parseKeyTag(
    String tag,
    String baseUrl,
    Map<String, String>? headers,
  ) async {
    final methodMatch = RegExp(r'METHOD=([^,\s"]+)').firstMatch(tag);
    final method = methodMatch?.group(1) ?? 'NONE';

    if (method == 'NONE') return const HlsSegmentKey(method: 'NONE');

    final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(tag);
    final ivMatch = RegExp(r'IV=0x([0-9a-fA-F]+)').firstMatch(tag);

    final keyUri = uriMatch?.group(1);
    Uint8List? keyBytes;
    Uint8List? iv;

    if (keyUri != null) {
      final resolvedKeyUrl = _resolveUrl(keyUri, baseUrl);
      keyBytes = await _fetchBytes(resolvedKeyUrl, headers);
    }
    if (ivMatch != null) {
      iv = _hexToBytes(ivMatch.group(1)!.padLeft(32, '0'));
    }

    return HlsSegmentKey(
        method: method, uri: keyUri, keyBytes: keyBytes, iv: iv);
  }

  static String _resolveUrl(String href, String base) {
    if (href.startsWith('http://') || href.startsWith('https://')) return href;
    final baseUri = Uri.parse(base);
    return baseUri.resolve(href).toString();
  }

  static int? _extractMediaSequence(String body) {
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('#EXT-X-MEDIA-SEQUENCE')) continue;
      return int.tryParse(trimmed.split(':').last.trim());
    }
    return null;
  }

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  static String _extensionFor(String url) {
    final lower = url.toLowerCase().split('?').first;
    for (final ext in ['.mp4', '.mkv', '.avi', '.webm', '.mov', '.m3u8']) {
      if (lower.endsWith(ext)) return ext;
    }
    return '.mp4';
  }

  static String buildFileName({
    required String episodeNumber,
    required Map<String, String> sortMap,
    required String url,
    bool isHls = false,
  }) {
    final ext = isHls ? '.mkv' : _extensionFor(url);
    final season = sortMap['season'];

    if (season != null && season.isNotEmpty) {
      return 'S${season}_EP$episodeNumber$ext';
    }
    return 'Episode $episodeNumber$ext';
  }

  static String sanitizePathSegment(String input) {
    final sanitized = input
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
    return sanitized.isEmpty ? 'unknown' : sanitized;
  }

  static String buildTaskId({
    required String extensionName,
    required String mediaTitle,
    required String episodeNumber,
    required Map<String, String> sortMap,
  }) {
    final sortPart = sortMap.isEmpty ? '' : '_${sortMap.values.join('_')}';
    return 'dl_${sanitizePathSegment(extensionName)}_ep$episodeNumber${sortPart}_${DateTime.now().millisecondsSinceEpoch % 100000}_${Random().nextInt(9999)}';
  }

  static String pickBestMatchingVideo(
      List<String> qualityLabels, String preferred) {
    if (qualityLabels.isEmpty) return '';

    final preferredLower = preferred.toLowerCase();
    final isPreferredDub = preferredLower.contains('dub');
    final isPreferredSub = preferredLower.contains('sub');
    final preferredRes =
        RegExp(r'\d{3,4}p').firstMatch(preferredLower)?.group(0);

    final scored = qualityLabels.map((label) {
      int score = 0;
      final labelLower = label.toLowerCase();
      final isDub = labelLower.contains('dub');
      final isSub = labelLower.contains('sub');
      final res = RegExp(r'\d{3,4}p').firstMatch(labelLower)?.group(0);

      if (preferredRes != null && res == preferredRes) {
        score += 100;
      } else if (res != null && preferredRes != null) {
        score -= 50;
      }

      if (isPreferredDub && isDub) score += 80;
      if (isPreferredSub && isSub) score += 80;
      if (labelLower == preferredLower) score += 200;
      if (labelLower.contains(preferredLower) ||
          preferredLower.contains(labelLower)) {
        score += 20;
      }

      return MapEntry(label, score);
    }).toList();

    scored.sort((a, b) => b.value.compareTo(a.value));
    final best = scored.first;

    if (best.value < 20) return qualityLabels.first;

    return best.key;
  }
}

class MediaDownloaderException implements Exception {
  final String message;
  final dynamic originalError;

  MediaDownloaderException(this.message, [this.originalError]);

  @override
  String toString() =>
      'MediaDownloaderException: $message${originalError != null ? ' ($originalError)' : ''}';
}
