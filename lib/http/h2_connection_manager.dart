import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:http2/transport.dart';

/// HTTP/2 connections with TCP_NODELAY on.
///
/// dart:io leaves Nagle's algorithm on for a [SecureSocket], and HTTP/2
/// writes small frames one after another on one connection: a request's
/// HEADERS, then (the adapter's GET) an empty DATA frame ending it, plus
/// WINDOW_UPDATEs and SETTINGS acks. With Nagle on, a small write waits
/// for the ACK of the one before, which the server delays: measured to
/// Bilibili's API from abroad, a request on an open connection took two
/// round trips (about 330ms) instead of one (160ms), and HTTP/2 came out
/// slower than HTTP/1.1. With TCP_NODELAY, one round trip every time.
///
/// The package's own manager gives no hold of the socket; this one is
/// what it does without a proxy (a proxy goes through the package's).
class NoDelayConnectionManager implements ConnectionManager {
  NoDelayConnectionManager({
    required this.idleTimeout,
    this.onBadCertificate,
    this.handshakeTimeout = const Duration(seconds: 15),
  });

  final Duration idleTimeout;
  final Duration handshakeTimeout;
  final bool Function(X509Certificate certificate)? onBadCertificate;

  final _connections = <String, _Connection>{};
  final _connecting = <String, Future<_Connection>>{};
  bool _closed = false;

  @override
  int get cachedConnectionsCount => _connections.length;

  @override
  Future<ClientTransportConnection> getConnection(
    RequestOptions options,
    List<RedirectRecord> redirects,
  ) async {
    if (_closed) {
      throw StateError("Can't connect after the ConnectionManager closed");
    }
    var uri = options.uri;
    if (redirects.isNotEmpty) {
      uri = Http2Adapter.resolveRedirectUri(uri, redirects.last.location);
    }
    final key = '${uri.scheme}://${uri.host}:${uri.port}';
    if (_connections[key] case final open?) {
      if (open.transport.isOpen) return open.transport;
      _connections.remove(key);
      open.dispose();
    }
    // Requests sent together share the one connection being made. (A
    // block, not `=>`: whenComplete waits for a future its callback
    // returns, and remove returns this very future.)
    final connection = await (_connecting[key] ??=
        _connect(
          key,
          uri,
          options,
        ).whenComplete(() {
          _connecting.remove(key);
        }));
    if (_closed) {
      connection.dispose();
      throw StateError("Can't connect after the ConnectionManager closed");
    }
    _connections[key] = connection;
    return connection.transport;
  }

  Future<_Connection> _connect(
    String key,
    Uri uri,
    RequestOptions options,
  ) async {
    // Plain http: HTTP/1.1, through the adapter's fallback.
    if (uri.scheme != 'https') throw DioH2NotSupportedException(uri, null);
    final timeout = options.connectTimeout;
    final socket = await SecureSocket.connect(
      uri.host,
      uri.port,
      timeout: timeout != null && timeout > Duration.zero ? timeout : null,
      onBadCertificate: onBadCertificate,
      supportedProtocols: const ['h2'],
    ).timeout(handshakeTimeout);
    if (socket.selectedProtocol != 'h2') {
      socket.destroy();
      throw DioH2NotSupportedException(uri, socket.selectedProtocol);
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    late final _Connection connection;
    connection = _Connection(
      ClientTransportConnection.viaSocket(socket),
      idleTimeout,
      onIdle: () {
        if (identical(_connections[key], connection)) _connections.remove(key);
        connection.dispose();
      },
    );
    return connection;
  }

  @override
  void removeConnection(ClientTransportConnection transport) {
    _connections.removeWhere((_, connection) {
      if (!identical(connection.transport, transport)) return false;
      connection.dispose();
      return true;
    });
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final connection in _connections.values) {
      connection.dispose(force: force);
    }
    _connections.clear();
  }
}

/// A connection closed once it has had no request for [idleTimeout].
class _Connection {
  _Connection(this.transport, this.idleTimeout, {required this.onIdle}) {
    transport.onActiveStateChanged = (active) {
      _timer?.cancel();
      _timer = active ? null : Timer(idleTimeout, onIdle);
    };
    _timer = Timer(idleTimeout, onIdle);
  }

  final ClientTransportConnection transport;
  final Duration idleTimeout;
  final void Function() onIdle;
  Timer? _timer;

  void dispose({bool force = false}) {
    _timer?.cancel();
    _timer = null;
    if (force) {
      transport.terminate().ignore();
    } else {
      transport.finish().ignore();
    }
  }
}
