import 'dart:async';
import 'dart:convert' show utf8, jsonDecode;
import 'dart:io' show Platform, File;
import 'dart:math' show min;
import 'dart:ui';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/pair.dart';
import 'package:PiliPlus/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/action_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/post_segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_type.dart';
import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/media_list/media_list.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_pbp/data.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/models_new/video/video_stein_edgeinfo/data.dart';
import 'package:PiliPlus/pages/audio/view.dart';
import 'package:PiliPlus/pages/common/publish/publish_route.dart';
import 'package:PiliPlus/pages/search/widgets/search_text.dart';
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/pages/video/download_panel/view.dart';
import 'package:PiliPlus/pages/video/play_url_prefetch.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/medialist/view.dart';
import 'package:PiliPlus/pages/video/note/view.dart';
import 'package:PiliPlus/pages/video/post_panel/view.dart';
import 'package:PiliPlus/pages/video/send_danmaku/view.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/extension/nested_scroll_ext.dart';
import 'package:PiliPlus/utils/flight_log.dart';
import 'package:PiliPlus/utils/flight_mode.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/reply_scheme_helper.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/ripper_speed.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/subtitle_utils.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart' show Options;
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart'
    show ExtendedNestedScrollViewState;
import 'package:flutter/foundation.dart' show kDebugMode, compute;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:thread_ripper/quality_watch.dart';
import 'package:thread_ripper/speed_memory.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' hide Subtitle;

typedef SubtitleData = ({bool isData, String id});

class VideoDetailController extends GetxController
    with GetTickerProviderStateMixin, BlockMixin {
  /// 路由传参
  late final Map args;
  late String bvid;
  late int aid;
  late final RxInt cid;
  int? epId;
  int? seasonId;
  int? pgcType;
  late final String heroTag;
  late final RxString cover;

  // 视频类型 默认投稿视频
  late final VideoType videoType;
  @override
  late final isUgc = videoType == VideoType.ugc;
  VideoType? _actualVideoType;
  late final ugcIntroCtr = Get.find<UgcIntroController>(tag: heroTag);
  late final pgcIntroCtr = Get.find<PgcIntroController>(tag: heroTag);

  // 页面来源 稍后再看 收藏夹
  late bool isPlayAll;
  late SourceType sourceType;
  late BiliDownloadEntryInfo entry;
  @override
  late bool isFileSource;
  late bool _mediaDesc = false;
  late final RxList<MediaListItemModel> mediaList = <MediaListItemModel>[].obs;
  late String watchLaterTitle;

  /// tabs相关配置
  late TabController tabCtr;

  // 请求返回的视频信息
  late PlayUrlModel data;
  final RxBool videoState = false.obs;

  /// 播放器配置 画质 音质 解码格式
  final Rxn<VideoQuality> currentVideoQa = Rxn<VideoQuality>();
  AudioQuality? currentAudioQa;
  late VideoDecodeFormatType currentDecodeFormats;

  // 是否开始自动播放 存在多p的情况下，第二p需要为true
  final RxBool _autoPlay = Pref.autoPlayEnable.obs;

  final videoPlayerKey = GlobalKey();
  final childKey = GlobalKey<MiniScaffoldState>();

  final plPlayerController = PlPlayerController.getInstance()
    ..brightness.value = -1;
  bool get setSystemBrightness => plPlayerController.setSystemBrightness;
  bool get removeSafeArea => plPlayerController.removeSafeArea;
  double get uiScale => plPlayerController.uiScale;

  late VideoItem firstVideo;
  String? videoUrl;
  String? audioUrl;
  Duration? defaultST;
  Duration? playedTime;
  String playedTimePos(bool hasParams) {
    final pos = playedTime?.inMilliseconds;
    if (pos != null && pos > 0) {
      return '${hasParams ? '&' : '?'}t=${pos / 1000}';
    }
    return '';
  }

  // 亮度
  double? brightness;

  int? _rotate = PlatformUtils.isDesktop ? 0 : null;
  int calcRotate(int value) => (_rotate! + value) % 360;
  set rotate(int value) {
    if (_rotate == value) return;
    final player = plPlayerController.videoPlayerController;
    if (player == null) return;
    _rotate = value;
    player.setProperty('video-rotate', _rotate.toString());
  }

  late final headerCtrKey = GlobalKey<TimeBatteryMixin>();

  Box setting = GStorage.setting;

  // 预设的解码格式
  late List<VideoDecodeFormatType> preferCodecs = Pref.preferCodecs;

  bool get showReply => isFileSource
      ? false
      : isUgc
      ? plPlayerController.showVideoReply
      : plPlayerController.showBangumiReply;

  bool get showRelatedVideo =>
      isFileSource ? false : plPlayerController.showRelatedVideo;

  ScrollController? introScrollCtr;
  ScrollController get effectiveIntroScrollCtr =>
      introScrollCtr ??= ScrollController();

  PlayerStatus? playerStatus;

  late final scrollKey = GlobalKey<ExtendedNestedScrollViewState>();
  late final RxBool isVertical;
  late final RxDouble scrollRatio = 0.0.obs;

  ScrollController? _scrollCtr;
  ScrollController get scrollCtr => _scrollCtr ??= ScrollController();

  late bool isExpanding = false;
  late bool isCollapsing = false;

  late double minVideoHeight;
  late double maxVideoHeight;
  late double videoHeight;
  late double animHeight;

  AnimationController? animController;
  AnimationController get animationController =>
      animController ??= (AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      )..addListener(_animListener));

  void refreshPage() {
    scrollKey.currentState?.refresh();
  }

  void _animListener() {
    if (animationController.isForwardOrCompleted) {
      _calcAnimHeight();
      refreshPage();
    }
  }

  void _calcAnimHeight() {
    if (isExpanding) {
      animHeight = clampDouble(
        videoHeight * animationController.value,
        kToolbarHeight,
        videoHeight,
      );
    } else if (isCollapsing) {
      animHeight = clampDouble(
        maxVideoHeight -
            (maxVideoHeight - minVideoHeight) * animationController.value,
        minVideoHeight,
        maxVideoHeight,
      );
    }
  }

  void animToTop() {
    scrollKey.currentState?.animToTop();
  }

  bool _needAnimOnDimensionChanged(bool isVertical) {
    if (isFullScreen) {
      if (PlatformUtils.isMobile) {
        plPlayerController.changeOrientation(isVertical: isVertical);
      }
      return false;
    }
    return true;
  }

  @pragma('vm:notify-debugger-on-exception')
  void _setVideoHeight() {
    try {
      var width = firstVideo.width;
      var height = firstVideo.height;
      if (width == null || height == null) {
        if (isUgc && !isFileSource) {
          final cid = this.cid.value;
          final part = ugcIntroCtr.videoDetail.value.pages?.firstWhereOrNull(
            (e) => e.cid == cid,
          );
          if (part != null) {
            final dimension = part.dimension!;
            width = dimension.width!;
            height = dimension.height!;
          } else {
            return;
          }
        } else {
          return;
        }
      }
      final isVertical = height > width;
      if (_scrollCtr?.hasClients != true) {
        videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.isVertical.value != isVertical) {
          this.isVertical.value = isVertical;
          _needAnimOnDimensionChanged(isVertical);
        }
        return;
      }
      if (this.isVertical.value != isVertical) {
        this.isVertical.value = isVertical;
        double videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.videoHeight != videoHeight) {
          if (videoHeight > this.videoHeight) {
            // current minVideoHeight
            if (_needAnimOnDimensionChanged(isVertical)) {
              isExpanding = true;
              animationController.forward(
                from: (minVideoHeight - scrollCtr.offset) / maxVideoHeight,
              );
            }
            this.videoHeight = maxVideoHeight;
          } else {
            // current maxVideoHeight
            final currentHeight = (maxVideoHeight - scrollCtr.offset)
                .toPrecision(2);
            double minVideoHeightPrecise = minVideoHeight.toPrecision(2);
            if (currentHeight == minVideoHeightPrecise) {
              this.videoHeight = minVideoHeight;
              if (_needAnimOnDimensionChanged(isVertical)) {
                isExpanding = true;
                animationController.forward(from: 1);
              }
            } else if (currentHeight < minVideoHeightPrecise) {
              // expand
              if (_needAnimOnDimensionChanged(isVertical)) {
                isExpanding = true;
                animationController.forward(
                  from: currentHeight / minVideoHeight,
                );
              }
              this.videoHeight = minVideoHeight;
            } else {
              // collapse
              if (_needAnimOnDimensionChanged(isVertical)) {
                isCollapsing = true;
                animationController.forward(
                  from: scrollCtr.offset / (maxVideoHeight - minVideoHeight),
                );
              }
              this.videoHeight = minVideoHeight;
            }
          }
        }
      } else {
        if (scrollCtr.offset != 0) {
          isExpanding = true;
          animationController.forward(from: 1 - scrollCtr.offset / videoHeight);
        }
      }
    } catch (_) {}
  }

  final isLoginVideo = Accounts.get(AccountType.video).isLogin;

  late final watchProgress = GStorage.watchProgress;
  void cacheLocalProgress() {
    if (plPlayerController.playerStatus.isCompleted) {
      watchProgress.put(cid.value.toString(), entry.totalTimeMilli);
    } else if (playedTime case final playedTime?) {
      watchProgress.put(cid.value.toString(), playedTime.inMilliseconds);
    }
  }

  void _initLocalSkipIfNeeded() {
    if (plPlayerController.enableBlock) {
      resetBlock();
      if (entry.segments case final list? when list.isNotEmpty) {
        handleSBData(list);
      }
    }
  }

  void initFileSource(BiliDownloadEntryInfo entry) {
    this.entry = entry;
    // block
    _initLocalSkipIfNeeded();
    // viewPoint
    if (plPlayerController.showViewPoints) {
      final viewPoints = entry.viewPoints;
      if (viewPoints != null && viewPoints.isNotEmpty) {
        try {
          final duration = (entry.totalTimeMilli / 1000);
          viewPointList.value = viewPoints
              .map((e) => e.toSegment(duration))
              .toList();
        } catch (_) {
          if (kDebugMode) rethrow;
        }
      }
    }
    // subtitle
    final subtitles = entry.subtitles;
    if (subtitles != null && subtitles.isNotEmpty) {
      this.subtitles.assignAll(subtitles);
      vttSubtitlesIndex.value = 0;
    }
    // volume
    volume = entry.volume;
    firstVideo = VideoItem(
      id: entry.preferedVideoQuality,
      quality: VideoQuality.fromCode(entry.preferedVideoQuality),
      width: entry.ep?.width ?? entry.pageData?.width ?? 1,
      height: entry.ep?.height ?? entry.pageData?.height ?? 1,
    );
    if (watchProgress.get(cid.value.toString()) case final int progress?) {
      if (progress >= entry.totalTimeMilli - 400) {
        defaultST = Duration.zero;
      } else {
        defaultST = Duration(milliseconds: progress);
      }
    } else {
      defaultST = Duration.zero;
    }
    data = PlayUrlModel(timeLength: entry.totalTimeMilli);
    _setVideoHeight();
  }

  @override
  void onInit() {
    super.onInit();
    args = Get.arguments;
    videoType = args['videoType'];
    if (videoType == VideoType.pgc) {
      if (!isLoginVideo) {
        _actualVideoType = VideoType.ugc;
      }
    }

    bvid = args['bvid'];
    aid = args['aid'];
    cid = RxInt(args['cid']);
    epId = args['epId'];
    seasonId = args['seasonId'];
    pgcType = args['pgcType'];
    heroTag = args['heroTag'];
    cover = RxString(args['cover'] ?? '');
    isVertical = RxBool(args['isVertical'] ?? false);

    sourceType = args['sourceType'] ?? SourceType.normal;
    isFileSource = sourceType == SourceType.file;
    isPlayAll = sourceType != SourceType.normal && !isFileSource;
    if (isFileSource) {
      initFileSource(args['entry']);
    } else if (isPlayAll) {
      watchLaterTitle = args['favTitle'];
      _mediaDesc = args['desc'];
      getMediaList();
    }

    tabCtr = TabController(
      length: 2,
      vsync: this,
      initialIndex: Pref.defaultShowComment || args.containsKey(rootRpIdKey)
          ? 1
          : 0,
    );
  }

  Future<void> getMediaList({
    bool isReverse = false,
    bool isLoadPrevious = false,
  }) async {
    final count = args['count'];
    if (!isReverse && count != null && mediaList.length >= count) {
      return;
    }
    final res = await UserHttp.getMediaList(
      type: args['mediaType'] ?? sourceType.mediaType,
      bizId: args['mediaId'] ?? -1,
      ps: 20,
      direction: isLoadPrevious ? true : false,
      oid: isReverse
          ? null
          : mediaList.isEmpty
          ? args['isContinuePlaying'] == true
                ? args['oid']
                : null
          : isLoadPrevious
          ? mediaList.first.aid
          : mediaList.last.aid,
      otype: isReverse
          ? null
          : mediaList.isEmpty
          ? null
          : isLoadPrevious
          ? mediaList.first.type
          : mediaList.last.type,
      desc: _mediaDesc,
      sortField: args['sortField'] ?? 1,
      withCurrent: mediaList.isEmpty && args['isContinuePlaying'] == true
          ? true
          : false,
    );
    if (res case Success(:final response)) {
      if (response.mediaList.isNotEmpty) {
        if (isReverse) {
          mediaList.value = response.mediaList;
          for (final item in mediaList) {
            if (item.cid != null) {
              try {
                ugcIntroCtr.onChangeEpisode(item);
              } catch (_) {}
              break;
            }
          }
        } else if (isLoadPrevious) {
          mediaList.insertAll(0, response.mediaList);
        } else {
          mediaList.addAll(response.mediaList);
        }
      }
    } else {
      res.toast();
    }
  }

  void showMediaListPanel(BuildContext context) {
    if (mediaList.isNotEmpty) {
      Widget panel() => MediaListPanel(
        mediaList: mediaList,
        onChangeEpisode: (episode) {
          try {
            ugcIntroCtr.onChangeEpisode(episode);
          } catch (_) {}
        },
        panelTitle: watchLaterTitle,
        bvid: bvid,
        count: args['count'],
        loadMoreMedia: getMediaList,
        desc: _mediaDesc,
        onReverse: () {
          _mediaDesc = !_mediaDesc;
          getMediaList(isReverse: true);
        },
        loadPrevious: args['isContinuePlaying'] == true
            ? () => getMediaList(isLoadPrevious: true)
            : null,
        onDelete:
            sourceType == SourceType.watchLater ||
                (sourceType == SourceType.fav && args['isOwner'] == true)
            ? (item, index) async {
                if (sourceType == SourceType.watchLater) {
                  final res = await UserHttp.toViewDel(aids: item.aid!);
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                  }
                } else {
                  final res = await FavHttp.favVideo(
                    resources: '${item.aid}:${item.type}',
                    delIds: '${args['mediaId']}',
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                    SmartDialog.showToast('取消收藏');
                  } else {
                    res.toast();
                  }
                }
              }
            : null,
      );
      if (plPlayerController.isFullScreen.value || showVideoSheet) {
        PageUtils.showVideoBottomSheet(
          context,
          child: plPlayerController.darkVideoPage
              ? Theme(data: ThemeUtils.darkTheme, child: panel())
              : panel(),
        );
      } else {
        childKey.currentState?.showBottomSheet(
          constraints: const BoxConstraints(),
          (context) => panel(),
        );
      }
    } else {
      getMediaList();
    }
  }

  bool isPortrait = true;

  bool get horizontalScreen => plPlayerController.horizontalScreen;

  bool get showVideoSheet =>
      (!horizontalScreen && !isPortrait) || plPlayerController.isDesktopPip;

  @override
  late final RxString videoLabel = ''.obs;
  @override
  int? get timeLength => data.timeLength;
  @override
  BlockConfigMixin get blockConfig => plPlayerController;
  @override
  Player? get player => plPlayerController.videoPlayerController;
  @override
  bool get isFullScreen => plPlayerController.isFullScreen.value;
  @override
  bool get autoPlay => _autoPlay.value;
  set autoPlay(bool value) => _autoPlay.value = value;
  @override
  bool get preInitPlayer => plPlayerController.preInitPlayer;
  @override
  int get currPosInMilliseconds =>
      defaultST?.inMilliseconds ?? plPlayerController.positionInMilliseconds;
  @override
  Future<void> seekTo(Duration duration) => plPlayerController.seekTo(duration);

  @override
  Widget buildItem(Object item, Animation<double> animation) {
    final theme = ThemeUtils.theme;
    return Align(
      alignment: Alignment.centerLeft,
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(-1.0, 0.0),
            end: Offset.zero,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: GestureDetector(
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              if (details.delta.dx < 0) {
                onRemoveItem(listData.indexOf(item), item);
              }
            },
            child: SearchText(
              bgColor: theme.colorScheme.secondaryContainer.withValues(
                alpha: 0.8,
              ),
              textColor: theme.colorScheme.onSecondaryContainer,
              padding: const .symmetric(horizontal: 8, vertical: 4),
              fontSize: 14,
              text: item is SegmentModel
                  ? '跳过: ${item.segmentType.shortTitle}'
                  : '上次看到第${(item as int) + 1}P，点击跳转',
              onTap: (_) {
                if (item is int) {
                  try {
                    final part = ugcIntroCtr.videoDetail.value.pages![item];
                    ugcIntroCtr.onChangeEpisode(part);
                    SmartDialog.showToast('已跳至第${item + 1}P');
                  } catch (e) {
                    if (kDebugMode) debugPrint('$e');
                    SmartDialog.showToast('跳转失败');
                  }
                  onRemoveItem(listData.indexOf(item), item);
                } else if (item is SegmentModel) {
                  onSkip(item);
                  onRemoveItem(listData.indexOf(item), item);
                }
              },
            ),
          ),
        ),
      ),
    );
  }

  ({int mode, int fontSize, Color color})? dmConfig;
  String? savedDanmaku;

  /// 发送弹幕
  Future<void> showShootDanmakuSheet() async {
    if (plPlayerController.dmState.contains(cid.value)) {
      SmartDialog.showToast('UP主已关闭弹幕');
      return;
    }
    final isPlaying =
        _autoPlay.value && plPlayerController.playerStatus.isPlaying;
    if (isPlaying) {
      await plPlayerController.pause();
    }
    await Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (buildContext, animation, secondaryAnimation) {
          final child = SendDanmakuPanel(
            cid: cid.value,
            bvid: bvid,
            progress: plPlayerController.positionInMilliseconds,
            initialValue: savedDanmaku,
            onSave: (danmaku) => savedDanmaku = danmaku,
            onSuccess: (danmakuModel) {
              savedDanmaku = null;
              plPlayerController.danmakuController?.addDanmaku(danmakuModel);
            },
            dmConfig: dmConfig,
            onSaveDmConfig: (dmConfig) => this.dmConfig = dmConfig,
          );
          if (plPlayerController.darkVideoPage) {
            return Theme(data: ThemeUtils.darkTheme, child: child);
          }
          return child;
        },
      ),
    );
    if (isPlaying) {
      plPlayerController.play();
    }
  }

  VideoItem findVideoByQa(int qa, {bool setCodecs = false}) {
    /// 根据currentVideoQa和currentDecodeFormats 重新设置videoUrl
    final videoList = data.dash!.video!.where((i) => i.id == qa).toList();

    final currentCodes = currentDecodeFormats.codes;
    VideoItem? bestVideo;
    int bestIndex = preferCodecs.length;
    for (final video in videoList) {
      final codecs = video.codecs!;
      if (currentCodes.any(codecs.startsWith)) {
        return video;
      }
      for (int i = 0; i < bestIndex; i++) {
        if (preferCodecs[i].codes.any(codecs.startsWith)) {
          bestIndex = i;
          bestVideo = video;
          break;
        }
      }
    }

    if (setCodecs) {
      if (bestIndex < preferCodecs.length) {
        currentDecodeFormats = preferCodecs[bestIndex];
      } else {
        currentDecodeFormats = VideoDecodeFormatType.fromString(
          videoList.first.codecs!,
        );
      }
    }

    return bestVideo ?? videoList.first;
  }

  /// 更新画质、音质
  void updatePlayer() {
    final currentVideoQa = this.currentVideoQa.value;
    if (currentVideoQa == null) return;
    final audioBefore = audioUrl;

    firstVideo = findVideoByQa(currentVideoQa.code, setCodecs: true);
    videoUrl = VideoUtils.getCdnUrl(firstVideo.playUrls);

    /// 根据currentAudioQa 重新设置audioUrl
    if (currentAudioQa != null) {
      final firstAudio = data.dash!.audio!.firstWhere(
        (i) => i.id == currentAudioQa!.code,
        orElse: () => data.dash!.audio!.first,
      );
      audioUrl = VideoUtils.getCdnUrl(firstAudio.playUrls, isAudio: true);
    }

    void reopen() {
      _autoPlay.value = true;
      playedTime = plPlayerController.videoPlayerController?.state.position;
      plPlayerController
        ..isBuffering.value = false
        ..buffered.value = 0;
      playerInit();
    }

    // Only the picture's quality changes: the player changes its video
    // track with the sound going on, where the file playing has that
    // quality as a track (PlPlayerController.switchVideoStream). Opened
    // again as before where it has not, or where that did not bring a
    // picture.
    final turn = ++_qualityTurn;
    if (audioUrl == audioBefore && !isFileSource && data.dash != null) {
      plPlayerController
          .switchVideoStream(firstVideo.id, _networkSource())
          .then(
            (done) {
              if (!done && turn == _qualityTurn) reopen();
            },
            onError: (Object _) {
              if (turn == _qualityTurn) reopen();
            },
          );
      return;
    }
    reopen();
  }

  /// Counts the changes of quality: one that fails after a later one was
  /// asked for leaves the reopening to that one.
  int _qualityTurn = 0;

  /// What the player is given to play, as the page has it now.
  NetworkSource _networkSource() {
    final audioItem = data.dash?.audio
        ?.where(
          (item) =>
              item.id == currentAudioQa?.code &&
              audioUrl == VideoUtils.getCdnUrl(item.playUrls, isAudio: true),
        )
        .firstOrNull;
    final videoBitrate = data.dash != null ? firstVideo.bandWidth : null;
    final proxied =
        data.dash != null &&
        _ripperEpisodeAllowed &&
        videoUrl == VideoUtils.getCdnUrl(firstVideo.playUrls);
    return NetworkSource(
      videoSource: videoUrl!,
      audioSource: audioUrl,
      videoCandidates: proxied ? firstVideo.playUrls.toList() : null,
      audioCandidates: audioItem?.playUrls.toList(),
      bitrate: videoBitrate == null || videoBitrate <= 0
          ? null
          : videoBitrate + (audioItem?.bandWidth ?? 0),
      videoQuality: proxied ? firstVideo.id : null,
      videoAlternates: proxied ? _otherQualities() : null,
    );
  }

  /// The video's other qualities, each the stream that would play at it
  /// (its codec's, as for the one playing): tracks the player can change
  /// to without opening the video again.
  List<VideoAlternate>? _otherQualities() {
    if (!Pref.threadRipperSeamlessQuality) return null;
    final videos = data.dash?.video;
    if (videos == null) return null;
    try {
      final seen = {firstVideo.id};
      final others = <VideoAlternate>[];
      for (final video in videos) {
        if (!seen.add(video.id)) continue;
        final stream = findVideoByQa(video.id);
        final codecs = stream.codecs ?? '';
        final codec = codecs.startsWith('avc')
            ? 'h264'
            : codecs.startsWith('hev') ||
                  codecs.startsWith('hvc') ||
                  codecs.startsWith('dvh')
            ? 'hevc'
            : codecs.startsWith('av01')
            ? 'av1'
            : null;
        final urls = stream.playUrls.toList();
        if (codec == null || urls.isEmpty) continue;
        // "30", "29.970" or "30000/1001".
        final rate = (stream.frameRate ?? '').split('/');
        final frames = double.tryParse(rate.first);
        final per = rate.length > 1 ? double.tryParse(rate[1]) : 1.0;
        others.add(
          VideoAlternate(
            quality: video.id,
            candidates: urls,
            codec: codec,
            width: stream.width,
            height: stream.height,
            fps: frames == null || per == null || per <= 0
                ? null
                : (frames / per).round(),
          ),
        );
      }
      return others.isEmpty ? null : others;
    } catch (_) {
      return null;
    }
  }

  Future<void>? initPlayerIfNeeded(bool autoFullScreenFlag) {
    if (_autoPlay.value ||
        (plPlayerController.preInitPlayer && !plPlayerController.processing) &&
            (isFileSource
                ? true
                : videoPlayerKey.currentState?.mounted == true)) {
      return playerInit(
        autoFullScreenFlag: autoFullScreenFlag && _autoPlay.value,
      );
    }
    return null;
  }

  // 剧集加速 (thread-ripper 2026.10.8.1): episodes go through the proxy unless
  // switched off; DRM and preview-only episodes never do.
  bool get _ripperEpisodeAllowed =>
      videoType != VideoType.pgc ||
      (Pref.threadRipperEpisodeEnabled && !data.isDrm && !data.isPreview);

  Future<void> playerInit({
    bool? autoplay,
    bool autoFullScreenFlag = false,
  }) async {
    // Back on a page that has no play address (yet): a log showed "Null
    // check operator used on a null value" here, called from the page's
    // didPopNext. The request for the address starts the player itself
    // when it is answered.
    if (!isFileSource && videoUrl == null) return;
    Duration? seek = defaultST ?? playedTime;
    if (seek == .zero) seek = null;
    // Where the history left it (not a change of quality or a reopening,
    // which go on where the picture is, nor a segment skipped): the
    // keyframe before will do, and is there sooner.
    final resumed = seek != null && defaultST != null;
    seek ??= getFirstSegment();
    await plPlayerController.setDataSource(
      isFileSource
          ? FileSource(
              dir: args['dirPath'],
              typeTag: entry.typeTag!,
              isMp4: entry.mediaType == 1,
              hasDashAudio: entry.hasDashAudio,
            )
          : _networkSource(),
      seekTo: seek,
      keyframeStart: resumed,
      duration: data.timeLength == null
          ? null
          : Duration(milliseconds: data.timeLength!),
      isVertical: isVertical.value,
      aid: aid,
      bvid: bvid,
      cid: cid.value,
      autoplay: autoplay ?? _autoPlay.value,
      epid: isUgc ? null : epId,
      seasonId: isUgc ? null : seasonId,
      pgcType: isUgc ? null : pgcType,
      videoType: videoType,
      onInit: () {
        videoState.value = true;
        setSubtitle(vttSubtitlesIndex.value);
      },
      width: firstVideo.width,
      height: firstVideo.height,
      volume: volume,
      autoFullScreenFlag: autoFullScreenFlag,
      rotate: _rotate,
    );

    if (isClosed) return;

    if (plPlayerController.enableBlock) {
      initSkip();
    }

    if (!isFileSource) {
      if (vttSubtitlesIndex.value == -1) {
        _queryPlayInfo();
      }

      if (plPlayerController.showDmChart && dmTrend.value == null) {
        _getDmTrend();
      }
    }

    defaultST = null;
  }

  bool isQuerying = false;

  final languages = Rxn<List<LanguageItem>>();
  final currLang = Rxn<String>();
  void setLanguage(String language) {
    if (currLang.value == language) return;
    if (!isLoginVideo) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    currLang.value = language;
    queryVideoUrl(fromReset: true);
  }

  /// [video]: another video than this one (the next in a list, fetched
  /// ahead, see [prepareNext]).
  Future<LoadingState<PlayUrlModel>> _getVideoUrl(
    int quality, {
    ({int cid, String bvid, int? epId})? video,
  }) {
    return VideoHttp.videoUrl(
      cid: video?.cid ?? cid.value,
      bvid: video?.bvid ?? bvid,
      qn: quality,
      epid: video == null ? epId : video.epId,
      seasonId: seasonId,
      tryLook: plPlayerController.tryLook,
      videoType: _actualVideoType ?? videoType,
      language: video == null ? currLang.value : null,
      voiceBalance: plPlayerController.enableAudioNormalization,
    );
  }

  /// The sound a video starts on: the one set, or 机上模式's.
  int get _audioQaWanted =>
      FlightMode.on ? FlightMode.audioQa : plPlayerController.cacheAudioQa;

  /// The quality a video starts on: [want] (the one set), or a lower one
  /// of [videos] where the download speed measured lately does not carry
  /// [want]'s stream (see [RipperSpeed]). [want] itself when the setting is
  /// off, no speed is known, or the streams cannot be told.
  ///
  /// [forCid]: the video it is asked for, where the answer is to hold from
  /// the making ready of a video to its start (see [_flightQuality]).
  int _startQuality(
    List<VideoItem> videos,
    PlayUrlModel response,
    int want, {
    int? forCid,
  }) {
    // 机上模式: the lowest the video has, whatever is set or was measured
    // elsewhere; or one above it.
    if (FlightMode.on && videos.isNotEmpty) {
      return _flightQuality(videos, response, want, forCid);
    }
    if (!Pref.threadRipperStartQuality || videos.isEmpty) return want;
    final kbps = RipperSpeed.known();
    if (kbps == null) return want;
    final offered = _offeredStreams(videos, response, want);
    if (offered == null) return want;
    final picked = RipperSpeedMemory.pick(offered, kbps);
    // The quality set, not the one nearest to it that the video has: the
    // caller looks that up as before.
    return picked == offered.first.quality ? want : picked;
  }

  /// 机上模式's quality for a video: its lowest, or the one above that
  /// where the link has lately carried three times its picture and sound
  /// (FlightMode.carries), never above the quality set ([want]). One step
  /// and no more: what is spared goes into the ten minutes downloaded
  /// ahead, which is what plays when the link is gone.
  ///
  /// Decided once for a video ([forCid]) and kept ([_flightPick]): the
  /// next video's proxy is made ready minutes before it starts
  /// ([prepareNext]), on the stream decided then, and a start that decided
  /// otherwise would find that proxy holding the wrong stream and begin
  /// from nothing.
  int _flightQuality(
    List<VideoItem> videos,
    PlayUrlModel response,
    int want,
    int? forCid,
  ) {
    final qualities = videos.availableVideoQualities.toList()..sort();
    final lowest = qualities.first;
    if (_flightPick case final pick?
        when forCid != null &&
            pick.cid == forCid &&
            DateTime.now().difference(pick.at) < _nextFreshFor &&
            qualities.contains(pick.quality)) {
      return pick.quality;
    }
    var picked = lowest;
    if (qualities.length > 1 && qualities[1] <= want) {
      try {
        final up = VideoUtils.findTargetVideo(
          videos,
          qualities[1],
          response.acceptQuality,
          response.supportFormats!,
          preferCodecs,
        ).$4;
        final audios = response.dash?.audio;
        final sound = audios == null || audios.isEmpty
            ? 0
            : VideoUtils.findTargetAudio(audios, FlightMode.audioQa).bandWidth ??
                  64000;
        final picture = up.bandWidth ?? 0;
        if (up.id == qualities[1] &&
            picture > 0 &&
            FlightMode.carries(picture + sound)) {
          picked = up.id;
        }
      } catch (_) {}
    }
    if (forCid != null) {
      _flightPick = (cid: forCid, quality: picked, at: DateTime.now());
    }
    return picked;
  }

  ({int cid, int quality, DateTime at})? _flightPick;

  /// A new video starts on [stream]: whether that is a step above its
  /// lowest (机上模式), said in the start's log and to the viewer.
  void _noteFlightRaise(List<VideoItem> videos, VideoItem stream) {
    _flightRaisedTo = null;
    if (!FlightMode.on || videos.isEmpty) return;
    if (stream.id <= videos.availableVideoQualities.reduce(min)) return;
    _flightRaisedTo = stream.id;
    final kbps = FlightMode.linkKbps;
    FlightLog.event('raise', {
      'q': stream.id,
      'kbps': kbps,
      'kb': (stream.bandWidth ?? 0) ~/ 1000,
    });
    final name = VideoQuality.fromCode(stream.id).shortDesc;
    final speed = kbps == null ? '' : '约 ${(kbps / 1000).toStringAsFixed(1)} Mbit/s，';
    plPlayerController.noteBeforeOpen(
      DateTime.now(),
      '机上模式：网速$speed升一档到 $name（码率 ${(stream.bandWidth ?? 0) ~/ 1000} kbit/s）',
    );
    SmartDialog.showToast(
      '网速够用，这个视频升一档到 $name',
      displayTime: const Duration(seconds: 2),
    );
  }

  /// The quality this video was raised to in 机上模式 ([_flightQuality]);
  /// null if it was not, or has been taken back ([flightStepDown]).
  int? _flightRaisedTo;

  /// 机上模式: the quality a step above the lowest kept playback waiting
  /// (PlPlayerController's watch, [FlightMode.raisedWait]). The video is
  /// opened again at [position] on its lowest quality, on the addresses it
  /// has. False if this video was not raised, or the viewer has since
  /// chosen a quality by hand: nothing is done then.
  bool flightStepDown(Duration position) {
    final raised = _flightRaisedTo;
    _flightRaisedTo = null;
    if (raised == null || isFileSource || isQuerying) return false;
    final videos = data.dash?.video;
    if (videos == null ||
        videos.isEmpty ||
        currentVideoQa.value?.code != raised) {
      return false;
    }
    final lowest = videos.availableVideoQualities.reduce(min);
    if (lowest >= raised) return false;
    _flightPick = (cid: cid.value, quality: lowest, at: DateTime.now());
    // A change of quality under way leaves the reopening to this.
    _qualityTurn++;
    currentVideoQa.value = VideoQuality.fromCode(lowest);
    firstVideo = findVideoByQa(lowest, setCodecs: true);
    videoUrl = VideoUtils.getCdnUrl(firstVideo.playUrls);
    _autoPlay.value = true;
    playedTime = position;
    plPlayerController
      ..isBuffering.value = false
      ..buffered.value = 0;
    playerInit();
    return true;
  }

  /// The stream that plays at the quality set ([want]), then those of the
  /// qualities below it, best first, each with its bitrate: what a speed
  /// chooses among (RipperSpeedMemory.pick, [RipperQualityWatch]). Null if
  /// the streams cannot be told.
  List<({int quality, int bandwidth})>? _offeredStreams(
    List<VideoItem> videos,
    PlayUrlModel response,
    int want,
  ) {
    try {
      // The stream that would play at a quality: its codec's, as picked.
      VideoItem streamAt(int quality) => VideoUtils.findTargetVideo(
        videos,
        quality,
        response.acceptQuality,
        response.supportFormats!,
        preferCodecs,
      ).$4;
      final first = streamAt(want);
      final below =
          videos.availableVideoQualities
              .where((quality) => quality < first.id)
              .toList()
            ..sort((a, b) => b.compareTo(a));
      return [
        (quality: first.id, bandwidth: first.bandWidth ?? 0),
        for (final quality in below)
          if (streamAt(quality) case final stream when stream.id == quality)
            (quality: quality, bandwidth: stream.bandWidth ?? 0),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Changes the quality of the video playing by the download speed, from
  /// its start to its end; null where there is nothing to choose among, or
  /// once the viewer has chosen a quality by hand.
  RipperQualityWatch? _qualityWatch;

  /// A speed the proxy measured, in the foreground (PlPlayerController's
  /// onRipperSpeed, set by the page showing).
  void onRipperSpeed(int kbps, {required bool sustained}) {
    final watch = _qualityWatch;
    if (watch == null || !Pref.threadRipperLiveQuality) return;
    final player = plPlayerController;
    if (isQuerying ||
        player.processing ||
        player.switchingVideoStream ||
        isFileSource) {
      return;
    }
    // Not the quality the watch has: chosen by hand, and left at that.
    if (currentVideoQa.value?.code != watch.current) {
      _qualityWatch = null;
      return;
    }
    // A change starts playback, and a paused video is to stay paused.
    final state = player.videoPlayerController?.state;
    if (state == null || !player.playerStatus.isPlaying) return;
    // Not for the last half minute.
    if (state.duration > Duration.zero &&
        state.duration - state.position < const Duration(seconds: 30)) {
      return;
    }
    final from = watch.current;
    final to = watch.speed(
      kbps,
      sustained: sustained,
      now: DateTime.now(),
      // Held down for a faster look, it is the speed set that counts.
      rate: player.longPressStatus.value
          ? player.lastPlaybackSpeed
          : player.playbackSpeed,
    );
    if (to == null) return;
    if (data.dash?.video?.any((video) => video.id == to) != true) {
      _qualityWatch = null;
      return;
    }
    final speed = (kbps / 1000).toStringAsFixed(1);
    final fromName = VideoQuality.fromCode(from).shortDesc;
    final toName = VideoQuality.fromCode(to).shortDesc;
    final down = to < from;
    Utils.reportError(
      '[画质调整] ${down ? '降' : '升'}：$fromName → $toName，'
      '下载速度约 $speed Mbit/s（${sustained ? '播放等下载时测到' : '单个窗口的速度'}），'
      '码率 ${(firstVideo.bandWidth ?? 0) ~/ 1000} kbit/s，'
      '位置 ${state.position.inSeconds}s / ${state.duration.inSeconds}s',
    );
    SmartDialog.showToast(
      down ? '网速约 $speed Mbit/s，画质降到 $toName' : '网速够用了，画质升到 $toName',
      displayTime: const Duration(seconds: 2),
    );
    currentVideoQa.value = VideoQuality.fromCode(to);
    updatePlayer();
  }

  /// Told to the viewer, and to the start's log: the video starts below
  /// the quality set.
  void _sayStartQuality(List<VideoItem> videos, int set, int picked) {
    final kbps = RipperSpeed.known();
    if (kbps == null) return;
    final speed = (kbps / 1000).toStringAsFixed(1);
    final to = VideoQuality.fromCode(picked).shortDesc;
    final from = VideoQuality.fromCode(
      set > videos.first.id ? videos.first.id : set,
    ).shortDesc;
    plPlayerController.noteBeforeOpen(
      DateTime.now(),
      '下载速度约 $speed Mbit/s，带不动 $from，从 $to 开始',
    );
    SmartDialog.showToast(
      '网速约 $speed Mbit/s，先用 $to（设定 $from）',
      displayTime: const Duration(seconds: 2),
    );
  }

  /// The play addresses, with the qualities the first answer left out.
  /// [first]: the first request, already on its way ([PlayUrlPrefetch]);
  /// asked again when it failed.
  Future<LoadingState<PlayUrlModel>> _fetchPlayUrl({
    ({int cid, String bvid, int? epId})? video,
    Future<LoadingState<PlayUrlModel>>? first,
  }) async {
    final pressed = first == null ? null : await first;
    final LoadingState<PlayUrlModel> result = pressed is Success<PlayUrlModel>
        ? pressed
        : await _getVideoUrl(VideoQuality.hdrVivid.code, video: video);
    if (result case Success(:final response) when response.dash != null) {
      final quality = response.missingVideoQualityBelowHighest;
      if (quality != -1) {
        final more = _getVideoUrl(quality, video: video).then((more) {
          if (more case Success(response: final extra)) {
            response.dash!.video!.merge(extra.dash?.video);
          }
        });
        // The second request, one round trip more before every start, only
        // adds qualities below the highest: waited for when the one wanted
        // may be among them; otherwise it fills the quality menu meanwhile.
        final videos = response.dash!.video!;
        final want = plPlayerController.cacheVideoQa;
        if (want == null ||
            (want < videos.first.id &&
                !videos.availableVideoQualities.contains(want)) ||
            // The start may be on one of them ([_startQuality]).
            _startQuality(videos, response, want) != want) {
          await more;
        } else {
          more.ignore();
        }
      }
    }
    return result;
  }

  /// The next video's addresses, fetched while this one ends ([prepareNext]).
  ({
    int cid,
    int? epId,
    DateTime at,
    Future<LoadingState<PlayUrlModel>> result,
  })?
  _next;

  /// Signed addresses last a couple of hours; a next video fetched long ago
  /// (playback paused near the end) is fetched again.
  static const _nextFreshFor = Duration(minutes: 10);

  Future<LoadingState<PlayUrlModel>>? _takeNext() {
    final next = _next;
    if (next == null ||
        next.cid != cid.value ||
        (!isUgc && next.epId != epId)) {
      return null;
    }
    _next = null;
    // Asked for without a language (see [_getVideoUrl]): with one chosen,
    // the request made now carries it.
    if (currLang.value != null) return null;
    if (DateTime.now().difference(next.at) > _nextFreshFor) return null;
    return next.result;
  }

  /// When this page was made: the start of the wait for the first picture.
  final _pageAt = DateTime.now();
  bool _firstQuery = true;

  /// The address asked for as this video's card was pressed, when the
  /// first request here asks for just what it asked for: a plain video.
  Future<LoadingState<PlayUrlModel>>? _takePressed() {
    if ((_actualVideoType ?? videoType) != VideoType.ugc ||
        epId != null ||
        seasonId != null ||
        currLang.value != null) {
      return null;
    }
    return PlayUrlPrefetch.take(
      bvid: bvid,
      cid: cid.value,
      tryLook: plPlayerController.tryLook,
      voiceBalance: plPlayerController.enableAudioNormalization,
    );
  }

  /// Startup of the next video in a list (autoplay), done while this one
  /// ends: logs of a list played through showed each switch spend a second
  /// or two on the play address (two requests, one after the other) and
  /// two to five on the proxy's first bytes from a distant CDN, with the
  /// old picture up meanwhile. Called once this video has downloaded to its
  /// end (or nearly ended): its addresses, then a proxy for its tracks with
  /// their heads and first windows downloaded ([PlPlayerController.
  /// prepareNextProxy]). A switch to it takes both.
  Future<void> prepareNext(ugc.BaseEpisodeItem? episode) async {
    if (isFileSource || episode == null) return;
    // Paused at the end, 下一集 is still pressed (an ending song skipped);
    // one video on repeat has no next.
    if (plPlayerController.playRepeat == PlayRepeat.singleCycle) return;
    // Its request would go without the language chosen ([_takeNext]).
    if (currLang.value != null) return;
    final nextCid = episode.cid;
    final nextBvid = episode.bvid ?? bvid;
    final nextEpId = isUgc ? null : (episode.epId ?? episode.id);
    if (nextCid == null || nextCid == cid.value) return;
    if (_next case final next? when next.cid == nextCid) return;
    final result = _fetchPlayUrl(
      video: (cid: nextCid, bvid: nextBvid, epId: nextEpId),
    );
    _next = (cid: nextCid, epId: nextEpId, at: DateTime.now(), result: result);
    final answer = await result;
    if (isClosed || !identical(_next?.result, result)) return;
    if (answer case Success(:final response)) {
      final dash = response.dash;
      final videos = dash?.video;
      final cacheVideoQa = plPlayerController.cacheVideoQa;
      if (videos == null || videos.isEmpty || cacheVideoQa == null) return;
      if (videoType == VideoType.pgc &&
          !(Pref.threadRipperEpisodeEnabled &&
              !response.isDrm &&
              !response.isPreview)) {
        return;
      }
      // What [_queryVideoUrl] will pick.
      final (_, _, _, video) = VideoUtils.findTargetVideo(
        videos,
        _startQuality(videos, response, cacheVideoQa, forCid: nextCid),
        response.acceptQuality,
        response.supportFormats!,
        preferCodecs,
      );
      final audios = dash!.audio;
      final audio = audios == null || audios.isEmpty
          ? null
          : VideoUtils.findTargetAudio(audios, _audioQaWanted);
      plPlayerController.prepareNextProxy(
        video.playUrls.toList(),
        audio?.playUrls.toList(),
        videoBitrate: video.bandWidth,
        audioBitrate: audio?.bandWidth,
      );
    }
  }

  Volume? volume;

  // 视频链接
  /// TODO: merge [DownloadHttp.getVideoUrl].
  Future<void> queryVideoUrl({
    bool fromReset = false,
    bool autoFullScreenFlag = false,
  }) async {
    if (isFileSource) {
      return initPlayerIfNeeded(autoFullScreenFlag);
    }
    if (isQuerying) {
      return;
    }
    isQuerying = true;
    try {
      await _queryVideoUrl(fromReset, autoFullScreenFlag);
    } finally {
      isQuerying = false;
    }
  }

  @pragma('vm:prefer-inline')
  Future<void> _queryVideoUrl(bool fromReset, bool autoFullScreenFlag) async {
    // The CDN's connections open while the address is on its way.
    PlPlayerController.warmCdn();
    if (plPlayerController.enableSponsorBlock && isBlock && !fromReset) {
      querySponsorBlock(bvid: bvid, cid: cid.value);
    }
    if (PlatformUtils.isMobile || Platform.isLinux) {
      final isWiFi = await ConnectivityUtils.isWiFi;
      RipperSpeed.onWifi = isWiFi;
      if (plPlayerController.cacheVideoQa == null) {
        plPlayerController
          ..cacheVideoQa = isWiFi
              ? Pref.defaultVideoQa
              : Pref.defaultVideoQaCellular
          ..cacheAudioQa = isWiFi
              ? Pref.defaultAudioQa
              : Pref.defaultAudioQaCellular;
      }
      preferCodecs = isWiFi ? Pref.preferCodecs : Pref.preferCodecsCellular;
    }

    final askAt = DateTime.now();
    final next = _takeNext();
    final pressed = next == null && !fromReset ? _takePressed() : null;
    final result = await (next ?? _fetchPlayUrl(first: pressed));
    // For the start's log: the wait before the player had the video.
    if (_firstQuery) {
      _firstQuery = false;
      plPlayerController.noteBeforeOpen(_pageAt, '进入视频页');
      if (pressed != null && PlayUrlPrefetch.lastTakenAt != null) {
        plPlayerController.noteBeforeOpen(
          PlayUrlPrefetch.lastTakenAt!,
          '按下卡片，开始取播放地址',
        );
      }
    }
    plPlayerController
      ..noteBeforeOpen(
        askAt,
        next != null
            ? '用提前取好的下一集地址'
            : pressed != null
            ? '等按下卡片时发出的地址请求'
            : '开始取播放地址',
      )
      ..noteBeforeOpen(DateTime.now(), '取到播放地址');

    if (result case Success(:final response)) {
      data = response;

      languages.value = data.language?.items;
      currLang.value = data.curLanguage;

      volume = data.volume;

      if (!fromReset) {
        final progress = args.remove('progress');
        if (progress != null) {
          defaultST = Duration(milliseconds: progress);
        } else {
          defaultST = Duration(milliseconds: data.lastPlayTime);
        }
      }

      if (!isUgc && !fromReset && plPlayerController.enablePgcSkip) {
        if (data.clipInfoList case final clipInfoList?) {
          resetBlock();
          handleSBData(clipInfoList);
        }
      }

      if (data.acceptDesc?.contains('试看') == true) {
        SmartDialog.showToast(
          '该视频为专属视频，仅提供试看',
          displayTime: const Duration(seconds: 3),
        );
      }
      final dash = data.dash;
      if (dash == null) {
        if (data.durl case final durl?) {
          // it will cause all files to be opened simultaneously
          if (durl.length > 1) {
            // TODO: refa
            final sb = StringBuffer('edl://!no_chapters;');
            for (var i in durl) {
              final video = VideoUtils.getCdnUrl(i.playUrls);
              sb.write('%${video.length}%$video,length=${i.length! / 1000};');
            }
            videoUrl = sb.toString();
          } else {
            videoUrl = VideoUtils.getCdnUrl(durl.single.playUrls);
          }

          audioUrl = '';

          // 实际为FLV/MP4格式，但已被淘汰，这里仅做兜底处理
          final videoQuality = VideoQuality.fromFormat(
            data.quality!,
            data.supportFormats,
          );
          firstVideo = VideoItem(
            id: data.quality!,
            baseUrl: videoUrl,
            codecs: 'avc1',
            quality: videoQuality,
          );
          _setVideoHeight();
          currentDecodeFormats = VideoDecodeFormatType.AVC;
          currentVideoQa.value = videoQuality;
          await initPlayerIfNeeded(autoFullScreenFlag);
          return;
        } else {
          SmartDialog.showToast('视频资源不存在');
          _autoPlay.value = false;
          videoState.value = false;
          if (plPlayerController.isFullScreen.value) {
            plPlayerController.triggerFullScreen(status: false);
          }
          return;
        }
      }

      final video = dash.video;
      if (video == null || video.isEmpty) {
        Utils.reportError(
          'null or empty dash video:\n'
          'bvid: $bvid, cid: $cid, seasonId: $seasonId, epId: $epId, '
          'videoType: $_actualVideoType',
        );
        return;
      }
      final cacheVideoQa = plPlayerController.cacheVideoQa!;
      // Opened again (its stream broke off, its addresses ran out, another
      // language or node): the quality it plays, which may be one the start
      // chose below the one set. A new video: by the speed known.
      final int wantQa;
      if (fromReset) {
        wantQa = currentVideoQa.value?.code ?? cacheVideoQa;
      } else {
        wantQa = _startQuality(
          video,
          response,
          cacheVideoQa,
          forCid: cid.value,
        );
        if (wantQa != cacheVideoQa && !FlightMode.on) {
          _sayStartQuality(video, cacheVideoQa, wantQa);
        }
      }
      final (
        int targetQuality,
        FormatItem targetFormat,
        VideoDecodeFormatType targetDecode,
        VideoItem targetVideo,
      ) = VideoUtils.findTargetVideo(
        video,
        wantQa,
        response.acceptQuality,
        response.supportFormats!,
        preferCodecs,
      );
      firstVideo = targetVideo;
      currentDecodeFormats = targetDecode;
      currentVideoQa.value = VideoQuality.fromCode(targetQuality);
      if (!fromReset) _noteFlightRaise(video, targetVideo);
      // A new video: watched from the quality it starts on, up to the one
      // set. Opened again, the watch it has goes on.
      if (!fromReset) {
        // Not in 机上模式: a few fast seconds of such a link are no reason
        // to raise the quality, and there is none below the lowest.
        final offered = FlightMode.on
            ? null
            : _offeredStreams(video, response, cacheVideoQa);
        _qualityWatch =
            offered != null &&
                offered.length > 1 &&
                offered.any((stream) => stream.quality == targetQuality)
            ? RipperQualityWatch(offered: offered, current: targetQuality)
            : null;
      }
      _setVideoHeight();
      videoUrl = VideoUtils.getCdnUrl(firstVideo.playUrls);

      AudioItem? firstAudio;
      final audioList = dash.audio;
      if (audioList != null && audioList.isNotEmpty) {
        firstAudio = VideoUtils.findTargetAudio(audioList, _audioQaWanted);
        audioUrl = VideoUtils.getCdnUrl(firstAudio.playUrls, isAudio: true);
        currentAudioQa = AudioQuality.fromCode(firstAudio.id);
      } else {
        audioUrl = '';
      }
      await initPlayerIfNeeded(autoFullScreenFlag);
    } else {
      _autoPlay.value = false;
      videoState.value = false;
      if (plPlayerController.isFullScreen.value) {
        plPlayerController.triggerFullScreen(status: false);
      }
      result.toast();
    }
  }

  late final List<PostSegmentModel> postList = <PostSegmentModel>[];
  void onBlock(BuildContext context) {
    if (postList.isEmpty) {
      postList.add(
        PostSegmentModel(
          segment: Pair(
            first: 0,
            second: plPlayerController.positionInMilliseconds / 1000,
          ),
          category: SegmentType.sponsor,
          actionType: ActionType.skip,
        ),
      );
    }
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      final child = PostPanel(
        enableSlide: false,
        videoDetailController: this,
        plPlayerController: plPlayerController,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage
            ? Theme(data: ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => PostPanel(
          videoDetailController: this,
          plPlayerController: plPlayerController,
        ),
      );
    }
  }

  late final showVP = true.obs;
  late final viewPointList = <ViewPointSegment>[].obs;

  final RxList<Subtitle> subtitles = RxList<Subtitle>();
  final Map<int, SubtitleData> vttSubtitles = {};
  late final vttSubtitlesIndex = (-1).obs;
  Future<SubtitleData?> loadFileSubtitle({
    required String path,
    required String fileName,
  }) async {
    SubtitleData? data;
    final length = subtitles.length;
    if (SubtitleUtils.isJson(fileName)) {
      final file = File(path);
      final stream = file.openRead().transform(utf8.decoder);
      final buffer = StringBuffer();
      await for (final chunk in stream) {
        if (isClosed) return null;
        buffer.write(chunk);
      }
      if (isClosed) return null;
      String sub = buffer.toString();
      sub = await compute<List, String>(
        SubtitleUtils.json2Vtt,
        jsonDecode(sub)['body'],
      );
      if (isClosed) return null;
      data = (isData: true, id: sub);
      vttSubtitles[length] = data;
    } else {
      data = (isData: false, id: path);
      vttSubtitles[length] = data;
    }
    return data;
  }

  // 设定字幕轨道
  Future<void> setSubtitle(int index) async {
    if (index <= 0) {
      await plPlayerController.videoPlayerController?.setSubtitleTrack(.no());
      vttSubtitlesIndex.value = index;
      return;
    }

    var subtitle = vttSubtitles[index - 1];
    if (subtitle == null) {
      final rawSub = subtitles[index - 1];
      if (rawSub is LocalSubtitle) {
        subtitle = await loadFileSubtitle(
          path: rawSub.path,
          fileName: PathUtils.subtitleExt,
        );
      } else {
        final result = await VideoHttp.getSubtitles(
          subtitles[index - 1].subtitleUrl!,
        );
        if (!isClosed && result != null) {
          subtitle = (isData: true, id: result);
          vttSubtitles[index - 1] = subtitle;
        } else {
          return;
        }
      }
    }
    if (subtitle == null) return;
    await _setSub(index, subtitle);
  }

  Future<void> _setSub(int index, SubtitleData subtitle) async {
    final sub = subtitles[index - 1];

    String subUri = subtitle.id;
    if (subtitle.isData) {
      subUri = 'memory://$subUri';
    }
    await plPlayerController.videoPlayerController?.setSubtitleTrack(
      SubtitleTrack(subUri, sub.lanDoc, sub.lan, uri: true),
    );
    vttSubtitlesIndex.value = index;
  }

  // interactive video
  int? graphVersion;
  EdgeInfoData? steinEdgeInfo;
  late final RxBool showSteinEdgeInfo = false.obs;

  Future<void> getSteinEdgeInfo([int? edgeId]) async {
    steinEdgeInfo = null;
    try {
      final res = await Request().get(
        '/x/stein/edgeinfo_v2',
        queryParameters: {
          'bvid': bvid,
          'graph_version': graphVersion,
          'edge_id': ?edgeId,
        },
      );
      if (res.data['code'] == 0) {
        steinEdgeInfo = EdgeInfoData.fromJson(res.data['data']);
      } else {
        if (kDebugMode) {
          debugPrint('getSteinEdgeInfo error: ${res.data['message']}');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('getSteinEdgeInfo: $e');
    }
  }

  late bool continuePlayingPart = Pref.continuePlayingPart;

  Future<void> _queryPlayInfo() async {
    vttSubtitles.clear();
    vttSubtitlesIndex.value = 0;
    if (plPlayerController.showViewPoints) {
      viewPointList.clear();
    }
    final res = await VideoHttp.playInfo(
      bvid: bvid,
      cid: cid.value,
      seasonId: seasonId,
      epId: epId,
    );
    if (res case Success(:final response)) {
      // interactive video
      if (isUgc && graphVersion == null) {
        try {
          if (ugcIntroCtr.videoDetail.value.rights?.isSteinGate == 1) {
            graphVersion = response.interaction?.graphVersion;
            getSteinEdgeInfo();
          }
        } catch (e) {
          if (kDebugMode) debugPrint('handle stein: $e');
        }
      }

      if (isUgc && continuePlayingPart) {
        continuePlayingPart = false;
        final lastCid = response.lastPlayCid;
        if (lastCid != null && lastCid != 0 && lastCid != cid.value) {
          try {
            final pages = ugcIntroCtr.videoDetail.value.pages;
            if (pages != null && pages.length > 1) {
              final index = pages.indexWhere((item) => item.cid == lastCid);
              if (index != -1) {
                onAddItem(index);
              }
            }
          } catch (_) {}
        }
      }

      if (plPlayerController.showViewPoints &&
          response.viewPoints?.firstOrNull?.type == 2) {
        try {
          final duration = (data.timeLength! / 1000);
          viewPointList.value = response.viewPoints!
              .map((e) => e.toSegment(duration))
              .toList();
        } catch (_) {}
      }

      if (response.subtitle?.subtitles case final sub? when (sub.isNotEmpty)) {
        _setSubtitle(sub);
      } else if (!Accounts.main.isLogin) {
        final res = await DmGrpc.dmView(aid, cid.value);
        if (res case Success(:final response)) {
          if (DmGrpc.dmViewToSubtitle(response) case final sub?
              when (sub.isNotEmpty)) {
            _setSubtitle(sub);
          }
        } else {
          res.toast();
        }
      }
    }
  }

  Future<void> _setSubtitle(List<Subtitle> sub) async {
    subtitles.value = sub;
    final idx = switch (Pref.subtitlePreferenceV2) {
      .off => 0,
      .on => 1,
      .withoutAi => sub.first.lan.startsWith('ai') ? 0 : 1,
      .auto =>
        !sub.first.lan.startsWith('ai') ||
                (PlatformUtils.isMobile &&
                    (await FlutterVolumeController.getVolume() ?? 0.0) <= 0.0)
            ? 1
            : 0,
    };
    await setSubtitle(idx);
  }

  void updateMediaListHistory(int aid) {
    if (args['sortField'] != null) {
      VideoHttp.medialistHistory(
        desc: _mediaDesc ? 1 : 0,
        oid: aid,
        upperMid: args['mediaId'],
      );
    }
  }

  void makeHeartBeat() {
    if (plPlayerController.enableHeart &&
        !plPlayerController.playerStatus.isCompleted &&
        playedTime != null) {
      try {
        plPlayerController.makeHeartBeat(
          data.timeLength != null
              ? (data.timeLength! - playedTime!.inMilliseconds).abs() <= 1000
                    ? -1
                    : playedTime!.inSeconds
              : playedTime!.inSeconds,
          type: HeartBeatType.completed,
          isManual: true,
          aid: aid,
          bvid: bvid,
          cid: cid.value,
          epid: isUgc ? null : epId,
          seasonId: isUgc ? null : seasonId,
          pgcType: isUgc ? null : pgcType,
          videoType: videoType,
        );
      } catch (_) {}
    }
  }

  @override
  void onClose() {
    cid.close();
    if (isFileSource) {
      cacheLocalProgress();
    }
    introScrollCtr?.dispose();
    introScrollCtr = null;
    tabCtr.dispose();
    _scrollCtr?.dispose();
    animController
      ?..removeListener(_animListener)
      ..dispose();
    subtitles.clear();
    vttSubtitles.clear();
    super.onClose();
  }

  void onReset({bool isStein = false}) {
    if (isFileSource) {
      cacheLocalProgress();
    }

    // Another video from here on: not the last frame of this one meanwhile.
    plPlayerController.hideStalePicture();

    playedTime = null;
    defaultST = null;
    videoUrl = null;
    audioUrl = null;

    // danmaku
    savedDanmaku = null;

    // subtitle
    subtitles.clear();
    vttSubtitlesIndex.value = -1;
    vttSubtitles.clear();

    // sponsor block
    if (blockConfig.enableBlock) {
      resetBlock();
    }

    // view point
    if (plPlayerController.showViewPoints) {
      viewPointList.clear();
    }

    // volume
    volume = null;

    if (!isFileSource) {
      // language
      languages.value = null;
      currLang.value = null;

      // dm trend
      if (plPlayerController.showDmChart) {
        dmTrend.value = null;
      }

      // interactive video
      if (!isStein) {
        graphVersion = null;
      }
      steinEdgeInfo = null;
      showSteinEdgeInfo.value = false;
    }
  }

  late final Rx<LoadingState<List<double>>?> dmTrend =
      Rx<LoadingState<List<double>>?>(null);
  late final RxBool showDmTrendChart = true.obs;

  Future<void> _getDmTrend() async {
    dmTrend.value = LoadingState<List<double>>.loading();
    try {
      final res = await Request().get(
        'https://bvc.bilivideo.com/pbp/data',
        queryParameters: {
          'aid': aid,
          'bvid': bvid,
          'cid': cid.value,
          'r': 'loader',
        },
        options: Options(
          headers: {
            'user-agent': BrowserUa.pc,
            'origin': 'https://www.bilibili.com',
            'referer': 'https://www.bilibili.com/video/$bvid',
          },
        ),
      );
      dynamic json;
      try {
        json = (res.data['modules'] as List).first['params']['data'];
      } catch (_) {
        json = res.data;
      }
      final data = PbpData.fromJson(json);
      final stepSec = data.stepSec ?? 0;
      if (stepSec != 0 && data.events?.eDefault?.isNotEmpty == true) {
        dmTrend.value = Success(data.events!.eDefault!);
        return;
      }
      dmTrend.value = const Error(null);
    } catch (e) {
      dmTrend.value = const Error(null);
      if (kDebugMode) debugPrint('_getDmTrend: $e');
    }
  }

  void showNoteList(BuildContext context) {
    String? title;
    try {
      title = ugcIntroCtr.videoDetail.value.title;
    } catch (_) {}
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      final child = NoteListPage(
        oid: aid,
        enableSlide: false,
        heroTag: heroTag,
        isStein: graphVersion != null,
        title: title,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage
            ? Theme(data: ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => NoteListPage(
          oid: aid,
          heroTag: heroTag,
          isStein: graphVersion != null,
          title: title,
        ),
      );
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  bool onSkipSegment() {
    try {
      if (plPlayerController.enableBlock) {
        if (listData.lastOrNull case final SegmentModel item) {
          onSkip(item);
          onRemoveItem(listData.indexOf(item), item);
          return true;
        }
      }
    } catch (e, s) {
      Utils.reportError(e, s);
    }
    return false;
  }

  void toAudioPage() {
    int? id;
    int? extraId;
    PlaylistSource from = PlaylistSource.UP_ARCHIVE;
    if (isPlayAll) {
      id = args['mediaId'];
      extraId = sourceType.extraId;
      from = sourceType.playlistSource!;
    } else if (isUgc) {
      try {
        id = ugcIntroCtr.videoDetail.value.ugcSeason?.id;
        if (id != null) {
          extraId = 8;
          from = PlaylistSource.MEDIA_LIST;
        }
      } catch (_) {}
    }
    AudioPage.toAudioPage(
      itemType: 1,
      id: id,
      oid: aid,
      subId: [cid.value],
      from: from,
      heroTag: _autoPlay.value ? heroTag : null,
      start: playedTime,
      audioUrl: audioUrl,
      extraId: extraId,
    );
  }

  Future<void> onDownload(BuildContext context) async {
    VideoDetailData? videoDetail;
    List<ugc.BaseEpisodeItem>? episodes;
    PgcInfoModel? pgcItem;
    if (isUgc) {
      try {
        videoDetail = ugcIntroCtr.videoDetail.value;
        if (videoDetail.ugcSeason?.sections case final sections?) {
          episodes = <ugc.BaseEpisodeItem>[];
          for (final i in sections) {
            if (i.episodes case final e?) {
              episodes.addAll(e);
            }
          }
        } else {
          episodes = videoDetail.pages;
        }
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('download ugc: $e\n\n$s');
        }
      }
    } else {
      try {
        pgcItem = pgcIntroCtr.pgcItem;
        episodes = pgcItem.episodes;
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('download pgc: $e\n\n$s');
        }
      }
    }
    if (episodes != null && episodes.isNotEmpty) {
      final downloadService = Get.find<DownloadService>();
      await downloadService.waitForInitialization;
      if (!context.mounted) {
        return;
      }
      final Set<int> cidSet = downloadService.downloadList
          .followedBy(downloadService.waitDownloadQueue)
          .map((e) => e.cid)
          .toSet();
      final targetCid = isUgc ? ugcIntroCtr.seasonCid ?? cid.value : cid.value;
      final index = episodes.indexWhere((e) => e.cid == targetCid);

      showModalBottomSheet(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxWidth: min(640, MediaQuery.shortestSideOf(context)),
        ),
        builder: (context) {
          final maxChildSize =
              PlatformUtils.isMobile && !MediaQuery.isPortraitOf(context)
              ? 1.0
              : 0.7;
          return DraggableScrollableSheet(
            snap: true,
            expand: false,
            minChildSize: 0,
            snapSizes: [maxChildSize],
            maxChildSize: maxChildSize,
            initialChildSize: maxChildSize,
            builder: (context, scrollController) => DownloadPanel(
              index: index,
              videoDetail: videoDetail,
              pgcItem: pgcItem,
              episodes: episodes!,
              scrollController: scrollController,
              videoDetailController: this,
              heroTag: heroTag,
              ugcIntroController: isUgc ? ugcIntroCtr : null,
              cidSet: cidSet,
            ),
          );
        },
      );
    }
  }

  void editPlayUrl() {
    String videoUrl = this.videoUrl ?? '';
    String audioUrl = this.audioUrl ?? '';
    Widget textField({
      required String label,
      required String initialValue,
      required ValueChanged<String> onChanged,
    }) => TextFormField(
      minLines: 1,
      maxLines: 3,
      onChanged: onChanged,
      initialValue: initialValue,
      decoration: InputDecoration(
        label: Text(label),
        border: const OutlineInputBorder(),
      ),
    );
    showDialog(
      context: Get.context!,
      builder: (context) => AlertDialog(
        constraints: Style.dialogFixedConstraints,
        title: const Text('播放地址'),
        content: Column(
          spacing: 20,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            textField(
              label: 'Video Url',
              initialValue: videoUrl,
              onChanged: (value) => videoUrl = value,
            ),
            textField(
              label: 'Audio Url',
              initialValue: audioUrl,
              onChanged: (value) => audioUrl = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
              this.videoUrl = videoUrl;
              this.audioUrl = audioUrl;
              playerInit();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> onCast() async {
    SmartDialog.showLoading();
    final res = await VideoHttp.tvPlayUrl(
      cid: cid.value,
      objectId: epId ?? aid,
      playurlType: epId != null ? 2 : 1,
      qn: currentVideoQa.value?.code,
    );
    SmartDialog.dismiss();
    if (res case Success(:final response)) {
      final first = response.durl?.firstOrNull;
      if (first == null || first.playUrls.isEmpty) {
        SmartDialog.showToast('不支持投屏');
        return;
      }
      final url = VideoUtils.getCdnUrl(first.playUrls);

      String? title;
      try {
        if (isUgc) {
          title = Get.find<UgcIntroController>(
            tag: heroTag,
          ).videoDetail.value.title;
        } else {
          title = Get.find<PgcIntroController>(
            tag: heroTag,
          ).videoDetail.value.title;
        }
      } catch (_) {}
      if (kDebugMode) {
        debugPrint(title);
      }
      Get.toNamed(
        '/dlna',
        parameters: {
          'url': url,
          'title': ?title,
        },
      );
    } else {
      res.toast();
    }
  }
}
