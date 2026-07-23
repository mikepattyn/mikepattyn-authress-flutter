import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

/// Web client that sends Authress session cookies on cross-origin calls.
http.Client createAuthressHttpClient() {
  final client = BrowserClient()..withCredentials = true;
  return client;
}
