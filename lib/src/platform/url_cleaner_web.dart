import 'package:web/web.dart' as web;

/// Drops Authress OAuth query params after a successful (or abandoned) exchange.
void clearAuthressCallbackQuery() {
  final uri = Uri.parse(web.window.location.href);
  if (uri.queryParameters.isEmpty) {
    return;
  }
  // Path-only replace strips tokens from the query without writing an absolute
  // URL that can interact badly with hash-based routing.
  final cleanedPath = uri.path.isEmpty ? '/' : uri.path;
  web.window.history.replaceState(null, '', cleanedPath);
}
