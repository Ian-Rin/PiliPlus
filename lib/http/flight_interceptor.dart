import 'package:PiliPlus/utils/flight_log.dart';
import 'package:dio/dio.dart';

/// 机上模式's record of the app's own requests (FlightLog.api): how long
/// each took and whether the server answered. Before the retries, so that
/// each try is one request. Does nothing while the record is off.
class FlightInterceptor extends Interceptor {
  static const _sentAt = 'flightSentAt';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // Whatever goes wrong here must not be the request's failure.
    try {
      if (FlightLog.recording) {
        options.extra[_sentAt] = DateTime.now().millisecondsSinceEpoch;
      }
    } catch (_) {}
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _note(response.requestOptions, answered: true);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    // One the app called off says nothing of the link.
    if (err.type != DioExceptionType.cancel) {
      _note(err.requestOptions, answered: err.response != null);
    }
    handler.next(err);
  }

  void _note(RequestOptions options, {required bool answered}) {
    try {
      final sent = options.extra.remove(_sentAt);
      if (sent is! int) return;
      FlightLog.api(
        DateTime.now().millisecondsSinceEpoch - sent,
        answered: answered,
      );
    } catch (_) {}
  }
}
