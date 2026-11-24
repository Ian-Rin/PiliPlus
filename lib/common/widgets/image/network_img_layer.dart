import 'dart:math' show max;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/flight_mode.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';

class NetworkImgLayer extends StatelessWidget {
  const NetworkImgLayer({
    super.key,
    required this.src,
    required this.width,
    required this.height,
    this.type = .def,
    this.fadeOutDuration = const Duration(milliseconds: 120),
    this.fadeInDuration = const Duration(milliseconds: 120),
    this.quality = 1,
    this.borderRadius = Style.mdRadius,
    this.getPlaceHolder,
    this.fit = .cover,
    this.alignment = .center,
    this.cacheWidth,
  });

  final String? src;
  final double width;
  final double height;
  final ImageType type;
  final Duration fadeOutDuration;
  final Duration fadeInDuration;
  final int quality;
  final BorderRadius borderRadius;
  final ValueGetter<Widget>? getPlaceHolder;
  final BoxFit fit;
  final Alignment alignment;
  final bool? cacheWidth;

  static Color? reduceLuxColor = Pref.reduceLuxColor;
  static bool reduce = false;

  @override
  Widget build(BuildContext context) {
    final isEmote = type == ImageType.emote;
    final isAvatar = type == ImageType.avatar;
    if (src?.isNotEmpty == true) {
      Widget child = _buildImage(context, isEmote: isEmote, isAvatar: isAvatar);
      if (isEmote) {
        return child;
      } else if (isAvatar) {
        return ClipOval(child: child);
      } else {
        return ClipRRect(borderRadius: borderRadius, child: child);
      }
    } else {
      return getPlaceHolder?.call() ??
          _placeholder(context, isEmote: isEmote, isAvatar: isAvatar);
    }
  }

  Widget _buildImage(
    BuildContext context, {
    required bool isEmote,
    required bool isAvatar,
  }) {
    int? memCacheWidth, memCacheHeight;
    if (cacheWidth ?? width <= height) {
      memCacheWidth = width.cacheSize(context);
    } else {
      memCacheHeight = height.cacheSize(context);
    }
    return CachedNetworkImage(
      gaplessPlayback: true,
      imageUrl: ImageUtils.thumbnailUrl(src, quality, _flightWidth),
      width: width,
      height: height,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      fit: fit,
      alignment: alignment,
      fadeOutDuration: fadeOutDuration,
      fadeInDuration: fadeInDuration,
      filterQuality: FilterQuality.low,
      placeholder: (_, _) =>
          getPlaceHolder?.call() ??
          _placeholder(context, isEmote: isEmote, isAvatar: isAvatar),
      errorBuilder: (_, _, _) =>
          _placeholder(context, isEmote: isEmote, isAvatar: isAvatar),
      colorBlendMode: reduce ? BlendMode.modulate : null,
      color: reduce ? reduceLuxColor : null,
    );
  }

  static const _flightWidths = [96, 160, 240, 320, 480];

  /// 机上模式: the picture is asked for at about the size it is shown (two
  /// pixels a point, the larger of its sides, the next of a few sizes up,
  /// 480 at most), not as large as it was uploaded. The covers of a page
  /// of the home feed, of a search or of the history are then some 150 KB
  /// together where they were 800: seconds less on a link that does
  /// 1 Mbit/s, and the video's share of it left alone.
  int? get _flightWidth {
    if (!FlightMode.on || type == ImageType.emote) return null;
    final side = max(width, height);
    if (!side.isFinite || side <= 0) return null;
    final need = side * 2;
    return _flightWidths.firstWhere(
      (w) => w >= need,
      orElse: () => _flightWidths.last,
    );
  }

  Widget _placeholder(
    BuildContext context, {
    required bool isEmote,
    required bool isAvatar,
  }) {
    return Container(
      width: width,
      height: height,
      clipBehavior: isEmote ? Clip.none : Clip.antiAlias,
      decoration: BoxDecoration(
        shape: isAvatar ? BoxShape.circle : BoxShape.rectangle,
        color: ColorScheme.of(context).onInverseSurface.withValues(alpha: 0.4),
        borderRadius: isEmote || isAvatar ? null : borderRadius,
      ),
      child: Center(
        child: Image.asset(
          isAvatar ? Assets.avatarPlaceHolder : Assets.loading,
          width: width,
          height: height,
          cacheWidth: width.cacheSize(context),
          colorBlendMode: reduce ? BlendMode.modulate : null,
          color: reduce ? reduceLuxColor : null,
        ),
      ),
    );
  }
}
