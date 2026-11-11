import 'dart:async';

import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:dio/dio.dart';
import 'package:http2/http2.dart';

/// A request that failed on the network, every try of it, in 我的 → 设置 →
/// 关于 → 错误日志: the error as dart:io gave it (a TLS handshake's says
/// what ended it), when each try failed, and how long after the API's
/// connections were last dropped for a network change.
abstract final class NetworkErrorLog {
  /// When the API's connections were last closed for a network change.
  static DateTime? poolResetAt;
  static int poolResets = 0;

  /// The first few of a run; a network gone for good would fill the log.
  static int _left = 40;

  static void _start(RequestOptions options) {
    options.extra['_t0'] ??= DateTime.now();
  }

  static void _note(DioException err) {
    final options = err.requestOptions;
    final t0 = options.extra['_t0'] as DateTime?;
    final ms = t0 == null ? '?' : DateTime.now().difference(t0).inMilliseconds;
    final what = err.error ?? err.message ?? '';
    ((options.extra['_errs'] ??= <String>[]) as List<String>).add(
      '${ms}ms ${err.type.name} $what',
    );
  }

  static void _report(RequestOptions options) {
    final tries = options.extra['_errs'] as List<String>?;
    if (tries == null || _left <= 0) return;
    _left--;
    final uri = options.uri;
    final reset = poolResetAt;
    Utils.reportError(
      '[网络错误] ${options.method} ${uri.host}${uri.path}'
      '（HTTP/2 ${Pref.enableHttp2 ? '开' : '关'}'
      '${reset == null ? '' : '，${DateTime.now().difference(reset).inSeconds}s 前因网络切换断开过全部连接（本次运行共 $poolResets 次）'}）'
      '\n${tries.join('\n')}',
    );
  }
}

class RetryInterceptor extends Interceptor {
  final Dio _client;
  final int _count;
  final int _delay;

  RetryInterceptor(this._client, this._count, this._delay);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    NetworkErrorLog._start(options);
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.responseType == ResponseType.stream) {
      return handler.next(err);
    }
    if (err.response != null) {
      final options = err.requestOptions;
      if (options.followRedirects && options.maxRedirects > 0) {
        final status = err.response!.statusCode;
        if (status != null && 300 <= status && status < 400) {
          var redirectUrl = err.response!.headers.value('location');
          if (redirectUrl != null) {
            var uri = Uri.parse(redirectUrl);
            if (!uri.hasScheme) {
              uri = options.uri.resolveUri(uri);
              redirectUrl = uri.toString();
            }
            (options..path = redirectUrl).maxRedirects--;
            if (status == 303) {
              options
                ..data = null
                ..method = 'GET';
            }
            _client
                .fetch(options)
                .then(
                  (i) => handler.resolve(
                    i
                      ..redirects.add(
                        RedirectRecord(status, options.method, uri),
                      )
                      ..isRedirect = true,
                  ),
                )
                .onError<DioException>((error, _) => handler.next(error));
            return;
          }
        }
      }
      return handler.next(err);
    } else {
      switch (err.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.unknown:
          NetworkErrorLog._note(err);
          if ((err.requestOptions.extra['_rt'] ??= 0) < _count &&
              err.error
                  is! TransportConnectionException // 网络中断, 此时请求可能已经被服务器所接收
                  ) {
            Timer(
              Duration(
                milliseconds: ++err.requestOptions.extra['_rt'] * _delay,
              ),
              () => _client
                  .fetch(err.requestOptions)
                  .then(handler.resolve)
                  .onError<DioException>((error, _) => handler.reject(error)),
            );
          } else {
            NetworkErrorLog._report(err.requestOptions);
            handler.next(err);
          }
          return;
        default:
          return handler.next(err);
      }
    }
  }

  RetryInterceptor copyWith({Dio? client, int? count, int? delay}) =>
      .new(client ?? _client, count ?? _count, delay ?? _delay);
}
