// Browser primitives that Bilibili-thread-ripper's downloader relies on, kept
// to the semantics the upstream code depends on (MIT, see
// docs/licenses/bilibili-thread-ripper.txt).
import 'dart:async';

/// A DOMException or an Error as upstream throws them. The downloader tells
/// failures apart by [name] ("AbortError", "TimeoutError") and by the HTTP
/// [status] of a refused range.
class RipperError implements Exception {
  RipperError(this.message, {this.name = 'Error', this.status});

  RipperError.abort([this.message = '播放器任务已取消'])
    : name = 'AbortError',
      status = null;

  RipperError.timeout(this.message) : name = 'TimeoutError', status = null;

  final String name;
  final String message;
  final int? status;

  @override
  String toString() => '$name: $message';
}

/// `error?.name` for any thrown object.
String errorName(Object? error) => error is RipperError ? error.name : 'Error';

/// `error?.status` for any thrown object.
int? errorStatus(Object? error) => error is RipperError ? error.status : null;

/// Upstream `abortError(reason)`: the abort reason itself when it is an error,
/// otherwise a generic AbortError.
Object abortError(Object? reason) =>
    reason is Exception || reason is Error ? reason! : RipperError.abort();

/// Promise.any's rejection: every attempt failed. [errors] keeps the order of
/// the attempts, not the order they failed in.
class AggregateError implements Exception {
  AggregateError(this.errors);

  final List<Object?> errors;

  @override
  String toString() => 'AggregateError: ${errors.join(', ')}';
}

/// Promise.any: the first attempt to succeed, or an [AggregateError] once all
/// of them have failed.
Future<T> promiseAny<T>(List<Future<T>> futures) {
  final completer = Completer<T>();
  if (futures.isEmpty) {
    completer.completeError(AggregateError(const []));
    return completer.future;
  }
  final errors = List<Object?>.filled(futures.length, null);
  var pending = futures.length;
  for (var i = 0; i < futures.length; i++) {
    futures[i].then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error) {
        errors[i] = error;
        pending -= 1;
        if (pending == 0 && !completer.isCompleted) {
          completer.completeError(AggregateError(errors));
        }
      },
    );
  }
  return completer.future;
}

/// `aggregate?.errors?.at?.(-1) || aggregate`: the last attempt's error.
Object lastErrorOf(Object aggregate) =>
    aggregate is AggregateError && aggregate.errors.isNotEmpty
    ? aggregate.errors.last ?? aggregate
    : aggregate;

/// An AbortSignal: [aborted] once, with a [reason], and listeners that run
/// synchronously in the order they were added. Every upstream listener is
/// added with `{ once: true }`, and a signal aborts only once, so listeners
/// are dropped when they run.
class RipperAbortSignal {
  RipperAbortSignal._();

  bool _aborted = false;
  Object? _reason;
  final _listeners = <void Function()>[];

  bool get aborted => _aborted;
  Object? get reason => _reason;

  /// addEventListener("abort", listener, { once: true }). Adding the same
  /// listener twice keeps one, as in the DOM.
  void addListener(void Function() listener) {
    if (_aborted || _listeners.contains(listener)) return;
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
}

class RipperAbortController {
  final signal = RipperAbortSignal._();

  /// controller.abort(reason): without a reason the signal gets an
  /// AbortError, as in the DOM.
  void abort([Object? reason]) {
    if (signal._aborted) return;
    signal
      .._aborted = true
      .._reason =
          reason ?? RipperError.abort('signal is aborted without reason');
    final listeners = List.of(signal._listeners);
    signal._listeners.clear();
    for (final listener in listeners) {
      // An exception in one listener does not keep the others from running.
      try {
        listener();
      } catch (error, stack) {
        Zone.current.handleUncaughtError(error, stack);
      }
    }
  }
}
