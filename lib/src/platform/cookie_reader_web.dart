import 'package:web/web.dart' as web;

/// Reads Authress browser cookies (`authorization`, `user`, `auth-code`, …).
Map<String, String> readAuthressCookies() {
  final raw = web.document.cookie;
  if (raw.isEmpty) {
    return const {};
  }

  final cookies = <String, String>{};
  for (final part in raw.split(';')) {
    final separator = part.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    final key = part.substring(0, separator).trim();
    final value = part.substring(separator + 1).trim();
    if (key.isEmpty || value.isEmpty) {
      continue;
    }
    try {
      cookies[key] = Uri.decodeComponent(value);
    } catch (_) {
      cookies[key] = value;
    }
  }
  return cookies;
}
