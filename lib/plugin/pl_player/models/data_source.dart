import 'package:PiliPlus/utils/path_utils.dart';
import 'package:path/path.dart' as path;

sealed class DataSource {
  final String videoSource;
  final String? audioSource;

  DataSource({
    required this.videoSource,
    required this.audioSource,
  });
}

/// Another quality of the video a [NetworkSource] plays: a stream the
/// player can change to as it plays, without opening the video again
/// (PlPlayerController.switchVideoStream).
class VideoAlternate {
  const VideoAlternate({
    required this.quality,
    required this.candidates,
    required this.codec,
    this.width,
    this.height,
    this.fps,
  });

  final int quality;

  /// Its addresses, as [NetworkSource.videoCandidates].
  final List<String> candidates;

  /// mpv's name of its codec ("h264", "hevc", "av1").
  final String codec;
  final int? width;
  final int? height;
  final int? fps;
}

class NetworkSource extends DataSource {
  final List<String>? videoCandidates;
  final List<String>? audioCandidates;

  /// Bits per second of the video and audio together, from the DASH
  /// manifest: sizes the player's cache (see `Pref.initBuffer`).
  final int? bitrate;

  /// The quality [videoSource] is, and the others the video has; null
  /// where there is nothing to change to.
  final int? videoQuality;
  final List<VideoAlternate>? videoAlternates;
  NetworkSource({
    this.videoCandidates,
    this.audioCandidates,
    this.bitrate,
    this.videoQuality,
    this.videoAlternates,
    required super.videoSource,
    required super.audioSource,
  });
}

class FileSource extends DataSource {
  final String dir;
  final bool isMp4;

  FileSource({
    required this.dir,
    required this.isMp4,
    required bool hasDashAudio,
    required String typeTag,
  }) : super(
         videoSource: path.join(
           dir,
           typeTag,
           isMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
         ),
         audioSource: isMp4 || !hasDashAudio
             ? null
             : path.join(dir, typeTag, PathUtils.audioNameType2),
       );
}
