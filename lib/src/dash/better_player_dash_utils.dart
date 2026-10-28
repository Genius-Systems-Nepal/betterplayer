import 'package:better_player/src/asms/better_player_asms_audio_track.dart';
import 'package:better_player/src/asms/better_player_asms_data_holder.dart';
import 'package:better_player/src/asms/better_player_asms_subtitle.dart';
import 'package:better_player/src/asms/better_player_asms_track.dart';
import 'package:better_player/src/core/better_player_utils.dart';
import 'package:better_player/src/hls/hls_parser/mime_types.dart';
import 'package:xml/xml.dart';

///DASH helper class
class BetterPlayerDashUtils {
  static Future<BetterPlayerAsmsDataHolder> parse(
      String data, String masterPlaylistUrl) async {
    List<BetterPlayerAsmsTrack> tracks = [];
    final List<BetterPlayerAsmsAudioTrack> audios = [];
    final List<BetterPlayerAsmsSubtitle> subtitles = [];
    try {
      int audiosCount = 0;
      final document = XmlDocument.parse(data);
      final adaptationSets = document.findAllElements('AdaptationSet');
      adaptationSets.forEach((node) {
        final mimeType = node.getAttribute('mimeType');

        if (mimeType != null) {
          if (MimeTypes.isVideo(mimeType)) {
            tracks = tracks + parseVideo(node);
          } else if (MimeTypes.isAudio(mimeType)) {
            audios.add(parseAudio(node, audiosCount));
            audiosCount += 1;
          } else if (MimeTypes.isText(mimeType)) {
            subtitles.add(parseSubtitle(masterPlaylistUrl, node));
          }
        }
      });
    } catch (exception) {
      BetterPlayerUtils.log("Exception on dash parse: $exception");
    }
    return BetterPlayerAsmsDataHolder(
        tracks: tracks, audios: audios, subtitles: subtitles);
  }

  static List<BetterPlayerAsmsTrack> parseVideo(XmlElement node) {
    final List<BetterPlayerAsmsTrack> tracks = [];

    final representations = node.findAllElements('Representation');

    for (final representation in representations) {
      try {
        final String? id = representation.getAttribute('id');
        final int width = int.tryParse(representation.getAttribute('width') ?? '0') ?? 0;
        final int height = int.tryParse(representation.getAttribute('height') ?? '0') ?? 0;
        final int bitrate = int.tryParse(representation.getAttribute('bandwidth') ?? '0') ?? 0;
        final int frameRate = _parseFrameRate(representation.getAttribute('frameRate'));
        final String? codecs = representation.getAttribute('codecs');
        final String? mimeType = MimeTypes.getMediaMimeType(codecs ?? '');
        tracks.add(BetterPlayerAsmsTrack(id, width, height, bitrate, frameRate, codecs, mimeType));
      } catch (exception) {
        BetterPlayerUtils.log("Exception on dash video representation parse: $exception");
      }
    }

    return tracks;
  }

  /// DASH may use integer (`24`) or fractional (`24/1`) frameRate values.
  static int _parseFrameRate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 0;
    final String head = raw.split('/').first.trim();
    return int.tryParse(head) ?? double.tryParse(head)?.round() ?? 0;
  }

  static BetterPlayerAsmsAudioTrack parseAudio(XmlElement node, int index) {
    final String segmentAlignmentStr =
        node.getAttribute('segmentAlignment') ?? '';
    String? label = node.getAttribute('label');
    final String? language = node.getAttribute('lang');
    final String? mimeType = node.getAttribute('mimeType');

    label ??= language;

    return BetterPlayerAsmsAudioTrack(
        id: index,
        segmentAlignment: segmentAlignmentStr.toLowerCase() == 'true',
        label: label,
        language: language,
        mimeType: mimeType);
  }

  static BetterPlayerAsmsSubtitle parseSubtitle(
      String masterPlaylistUrl, XmlElement node) {
    final String segmentAlignmentStr =
        node.getAttribute('segmentAlignment') ?? '';
    String? name = node.getAttribute('label');
    final String? language = node.getAttribute('lang');
    final String? mimeType = node.getAttribute('mimeType');
    String? url =
        node.getElement('Representation')?.getElement('BaseURL')?.text;
    if (url?.contains("http") == false) {
      final Uri masterPlaylistUri = Uri.parse(masterPlaylistUrl);
      final pathSegments = <String>[...masterPlaylistUri.pathSegments];
      pathSegments[pathSegments.length - 1] = url!;
      url = Uri(
              scheme: masterPlaylistUri.scheme,
              host: masterPlaylistUri.host,
              port: masterPlaylistUri.port,
              pathSegments: pathSegments)
          .toString();
    }

    if (url != null && url.startsWith('//')) {
      url = 'https:$url';
    }

    name ??= language;

    return BetterPlayerAsmsSubtitle(
        name: name,
        language: language,
        mimeType: mimeType,
        segmentAlignment: segmentAlignmentStr.toLowerCase() == 'true',
        url: url,
        realUrls: [url ?? '']);
  }
}
