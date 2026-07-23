import 'package:http/http.dart' as http;

/// Default HTTP client for non-web platforms.
http.Client createAuthressHttpClient() => http.Client();
