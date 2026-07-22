import 'package:web/web.dart' as web;

/// Drops Authress OAuth query params after a successful (or abandoned) exchange.
void clearAuthressCallbackQuery() {
  final uri = Uri.parse(web.window.location.href);
  if (uri.queryParameters.isEmpty) {
    return;
  }
  final cleaned = uri.replace(queryParameters: {});
  web.window.history.replaceState(null, '', cleaned.toString());
}
