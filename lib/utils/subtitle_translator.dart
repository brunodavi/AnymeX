import 'dart:convert';

import 'package:anymex/utils/logger.dart';
import 'package:anymex/utils/sub_parser.dart';
import 'package:http/http.dart' as http;

class SubtitleTranslator {
  SubtitleTranslator._();

  static const String _endpoint =
      'https://translate.googleapis.com/translate_a/single?client=gtx';

  /// Limite conservador para não traduzir legendas enormes em segundo plano.
  static const int maxCuesPerTrack = 800;

  static final Map<String, String> _cache = {};

  static final Map<String, String> languages = {
    'none': 'None (Original)',
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'it': 'Italian',
    'pt': 'Portuguese',
    'pt-BR': 'Portuguese (Brazil)',
    'ru': 'Russian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'zh-CN': 'Chinese (Simplified)',
    'zh-TW': 'Chinese (Traditional)',
    'hi': 'Hindi',
    'id': 'Indonesian',
    'vi': 'Vietnamese',
    'th': 'Thai',
    'ar': 'Arabic',
    'tr': 'Turkish',
    'nl': 'Dutch',
    'pl': 'Polish',
    'sv': 'Swedish',
  };

  static Future<String> translate(String text, String targetLang) async {
    if (targetLang == 'none' || text.trim().isEmpty) return text;
    final cacheKey = '$targetLang::${text.trim()}';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    try {
      final uri = Uri.parse(
        '$_endpoint&sl=auto&tl=${Uri.encodeComponent(targetLang)}&dt=t&q=${Uri.encodeComponent(text.trim())}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return text;

      final decoded = jsonDecode(response.body);
      final parts = decoded is List && decoded.isNotEmpty ? decoded[0] : null;
      if (parts is! List) return text;

      final translated = parts
          .whereType<List>()
          .map((e) => e.isNotEmpty ? e[0].toString() : '')
          .join()
          .trim();
      if (translated.isEmpty) return text;

      _cache[cacheKey] = translated;
      return translated;
    } catch (_) {
      return text;
    }
  }

  /// Traduz o texto de cada cue, preservando timestamps e textos repetidos.
  static Future<List<SubtitleCue>> translateCues(
    List<SubtitleCue> cues,
    String targetLang, {
    int concurrency = 6,
  }) async {
    if (cues.isEmpty || targetLang == 'none') return cues;

    final uniqueTexts = <String>[];
    final seen = <String>{};
    for (final cue in cues) {
      final t = cue.text.trim();
      if (t.isEmpty || !seen.add(t)) continue;
      uniqueTexts.add(t);
    }

    Logger.i(
      '[Translate] ${uniqueTexts.length} texto(s) único(s) para $targetLang',
    );

    for (var i = 0; i < uniqueTexts.length; i += concurrency) {
      final batch = uniqueTexts.skip(i).take(concurrency).toList();
      await Future.wait(
        batch.map((text) async {
          final result = await translate(text, targetLang);
          if (result != text) _cache['$targetLang::$text'] = result;
        }),
      );
    }

    return cues
        .map(
          (c) => SubtitleCue(
            start: c.start,
            end: c.end,
            text: _cache['$targetLang::${c.text.trim()}'] ?? c.text,
          ),
        )
        .toList();
  }

  /// Converte cues em SRT com os mesmos tempos de início/fim.
  static String buildSrt(List<SubtitleCue> cues) {
    final buffer = StringBuffer();
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      buffer
        ..writeln(i + 1)
        ..writeln('${_formatTime(cue.start)} --> ${_formatTime(cue.end)}')
        ..writeln(cue.text.replaceAll('\n', ' '))
        ..writeln();
    }
    return buffer.toString();
  }

  /// Helper usado pelo downloader: parseia, traduz e devolve um SRT pronto.
  static Future<String?> translateSubtitleToSrt({
    required String content,
    required String targetLang,
  }) async {
    if (targetLang == 'none') return null;
    try {
      final cues = await SubParser.parseSubtitles(content);
      if (cues.isEmpty) return null;
      if (cues.length > maxCuesPerTrack) {
        Logger.i(
          '[Translate] Pulando tradução: ${cues.length} cues > $maxCuesPerTrack',
        );
        return null;
      }
      final translated = await translateCues(cues, targetLang);
      return buildSrt(translated);
    } catch (e) {
      Logger.e('[Translate] Falha ao traduzir legenda: $e');
      return null;
    }
  }

  static String _formatTime(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    final millis = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds,$millis';
  }
}
