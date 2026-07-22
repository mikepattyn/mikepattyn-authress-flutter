import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mikepattyn_authress_login/src/models/deep_link_config.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/auth_config.dart';
import '../models/auth_state.dart';
import '../models/user_profile.dart';
import '../platform/url_cleaner.dart';
import 'crypto_service.dart';
import 'deep_link_service.dart';
import 'http_service.dart';
import 'token_service.dart';

/// Function type for canLaunchUrl
typedef CanLaunchUrlFn = Future<bool> Function(Uri url);

/// Function type for launchUrl
typedef LaunchUrlFn =
    Future<bool> Function(
      Uri url, {
      LaunchMode mode,
      WebViewConfiguration webViewConfiguration,
      String? webOnlyWindowName,
    });

/// Returns the current page URI (injectable for tests).
typedef CurrentUriFn = Uri Function();

/// Result of starting an Authress authentication request.
class AuthenticationStartResult {
  final String authenticationUrl;
  final String authenticationRequestId;
  final String redirectUrl;
  final String codeVerifier;

  const AuthenticationStartResult({
    required this.authenticationUrl,
    required this.authenticationRequestId,
    required this.redirectUrl,
    required this.codeVerifier,
  });
}

/// Main authentication service that orchestrates all auth-related operations
class AuthenticationService extends ChangeNotifier {
  final AuthressConfiguration _config;
  final TokenService _tokenService;
  final HttpService _httpService;
  final DeepLinkService _deepLinkService;
  final CryptoService _cryptoService;
  final CanLaunchUrlFn _canLaunchUrl;
  final LaunchUrlFn _launchUrl;
  final CurrentUriFn _currentUri;
  final bool _enableUriCallbackOnInit;

  AuthState _state = const AuthStateUnauthenticated();

  AuthenticationService._({
    required AuthressConfiguration config,
    required TokenService tokenService,
    required HttpService httpService,
    required DeepLinkService deepLinkService,
    required CryptoService cryptoService,
    CanLaunchUrlFn? canLaunchUrlFn,
    LaunchUrlFn? launchUrlFn,
    CurrentUriFn? currentUriFn,
    bool enableUriCallbackOnInit = false,
  }) : _config = config,
       _tokenService = tokenService,
       _httpService = httpService,
       _deepLinkService = deepLinkService,
       _cryptoService = cryptoService,
       _canLaunchUrl = canLaunchUrlFn ?? canLaunchUrl,
       _launchUrl = launchUrlFn ?? launchUrl,
       _currentUri = currentUriFn ?? (() => Uri.base),
       _enableUriCallbackOnInit = enableUriCallbackOnInit;

  /// Factory constructor with dependency injection
  factory AuthenticationService.create({
    required AuthressConfiguration config,
    DeepLinkConfig? deepLinkConfig,
  }) {
    final tokenService = TokenService();
    final httpService = HttpService(config);
    final deepLinkService = DeepLinkService(
      deepLinkConfig ?? const DeepLinkConfig(),
    );
    final cryptoService = CryptoService();

    return AuthenticationService._(
      config: config,
      tokenService: tokenService,
      httpService: httpService,
      deepLinkService: deepLinkService,
      cryptoService: cryptoService,
    );
  }

  /// Test constructor that allows dependency injection for testing
  @visibleForTesting
  factory AuthenticationService.forTesting({
    required AuthressConfiguration config,
    required TokenService tokenService,
    required HttpService httpService,
    required DeepLinkService deepLinkService,
    required CryptoService cryptoService,
    CanLaunchUrlFn? canLaunchUrlFn,
    LaunchUrlFn? launchUrlFn,
    CurrentUriFn? currentUriFn,
    bool enableUriCallbackOnInit = false,
  }) {
    return AuthenticationService._(
      config: config,
      tokenService: tokenService,
      httpService: httpService,
      deepLinkService: deepLinkService,
      cryptoService: cryptoService,
      canLaunchUrlFn: canLaunchUrlFn,
      launchUrlFn: launchUrlFn,
      currentUriFn: currentUriFn,
      enableUriCallbackOnInit: enableUriCallbackOnInit,
    );
  }

  /// Current authentication state
  AuthState get state => _state;

  /// Whether the user is currently authenticated
  bool get isAuthenticated => _state is AuthStateAuthenticated;

  /// Get the current access token if available
  String? get accessToken => _state is AuthStateAuthenticated ? (_state as AuthStateAuthenticated).accessToken : null;

  /// Get the current user profile if available
  UserProfile? get userProfile => _state is AuthStateAuthenticated ? (_state as AuthStateAuthenticated).user : null;

  /// Initialize the service and check for existing sessions
  Future<void> initialize() async {
    if (kIsWeb || _enableUriCallbackOnInit) {
      await _completeLoginFromCallbackIfPresent();
    } else {
      await _deepLinkService.initialize();
    }

    if (_state is AuthStateUnauthenticated) {
      await _checkExistingSession();
    }
  }

  /// Check if a user session exists and is valid
  Future<bool> _checkExistingSession() async {
    try {
      final storedAuth = await _tokenService.loadStoredTokens();
      if (storedAuth == null) {
        _setState(const AuthStateUnauthenticated());
        return false;
      }

      // Check if token is expired
      if (storedAuth.isTokenExpired) {
        final refreshed = await _attemptTokenRefresh();
        return refreshed;
      }

      // Token is valid, restore session
      _setState(storedAuth);
      _scheduleTokenRefresh(storedAuth.expiresAt);
      return true;
    } catch (e) {
      _setState(const AuthStateUnauthenticated());
      return false;
    }
  }

  /// Start authentication flow
  Future<void> authenticate({
    String? connectionId,
    String? tenantLookupIdentifier,
    Map<String, String>? additionalParams,
  }) async {
    _setState(const AuthStateLoading());

    try {
      final authStart = await _startAuthenticationRequest(
        connectionId: connectionId,
        tenantLookupIdentifier: tenantLookupIdentifier,
        additionalParams: additionalParams,
      );

      await _tokenService.storePendingAuth(
        nonce: authStart.authenticationRequestId,
        codeVerifier: authStart.codeVerifier,
        redirectUrl: authStart.redirectUrl,
      );

      if (!(await _canLaunchUrl(Uri.parse(authStart.authenticationUrl)))) {
        await _tokenService.clearPendingAuth();
        _setState(
          const AuthStateError(message: 'Cannot launch authentication URL'),
        );
        return;
      }

      if (kIsWeb) {
        await _launchUrl(
          Uri.parse(authStart.authenticationUrl),
          mode: LaunchMode.externalApplication,
          webOnlyWindowName: '_self',
        );
        // Page unloads for Hosted Login; callback completes on next initialize().
        return;
      }

      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _launchUrl(
          Uri.parse(authStart.authenticationUrl),
          mode: LaunchMode.inAppWebView,
          webViewConfiguration: const WebViewConfiguration(
            enableJavaScript: true,
            enableDomStorage: true,
          ),
        );
      } else {
        await _launchUrl(
          Uri.parse(authStart.authenticationUrl),
          mode: LaunchMode.externalApplication,
        );
      }

      final authParams = await _deepLinkService.waitForAuthCallback();

      if (authParams == null) {
        await _tokenService.clearPendingAuth();
        _setState(
          const AuthStateError(
            message: 'Authentication was cancelled or timed out',
          ),
        );
        return;
      }

      await _processAuthenticationCallback(authParams);
    } catch (e) {
      await _tokenService.clearPendingAuth();
      _setState(
        AuthStateError(
          message: 'Authentication failed: ${e.toString()}',
          error: e,
        ),
      );
    }
  }

  /// Complete OIDC login when the app reloads with code + nonce in the URL (web).
  Future<void> _completeLoginFromCallbackIfPresent() async {
    final params = _currentUri().queryParameters;
    final code = params['code'];
    final nonce = params['nonce'];
    if (code == null || nonce == null) {
      return;
    }

    try {
      await _processAuthenticationCallback(params);
    } catch (e) {
      _setState(
        AuthStateError(
          message: 'Authentication failed: ${e.toString()}',
          error: e,
        ),
      );
    } finally {
      await _tokenService.clearPendingAuth();
      clearAuthressCallbackQuery();
    }
  }

  /// Process authentication callback
  Future<void> _processAuthenticationCallback(
    Map<String, String> params,
  ) async {
    final error = params['error'];
    final code = params['code'];
    final nonce = params['nonce'];

    if (error != null) {
      throw Exception('Authentication error: $error');
    }

    if (code == null || nonce == null) {
      throw Exception('Missing authorization code or nonce in callback');
    }

    await _exchangeCodeForTokens(code, nonce);
  }

  /// Resolve redirect URL for the current platform.
  String _resolveRedirectUrl() {
    final configured = _config.redirectUrl ?? _deepLinkService.callbackUrl;
    if (kIsWeb && _isCustomSchemeRedirect(configured)) {
      return '${Uri.base.origin}/auth/callback';
    }
    return configured;
  }

  bool _isCustomSchemeRedirect(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.scheme != 'http' && uri.scheme != 'https';
  }

  /// Start Authress authentication and return redirect metadata.
  Future<AuthenticationStartResult> _startAuthenticationRequest({
    String? connectionId,
    String? tenantLookupIdentifier,
    Map<String, String>? additionalParams,
  }) async {
    final redirectUrl = _resolveRedirectUrl();
    final pkceCodes = _cryptoService.generatePKCECodes();

    final antiAbuseHash = await _cryptoService.calculateAntiAbuseHash({
      'connectionId': connectionId,
      'tenantLookupIdentifier': tenantLookupIdentifier,
      'applicationId': _config.applicationId,
    });

    final requestBody = {
      'antiAbuseHash': antiAbuseHash,
      'redirectUrl': redirectUrl,
      'codeChallengeMethod': pkceCodes.codeChallengeMethod,
      'codeChallenge': pkceCodes.codeChallenge,
      'applicationId': _config.applicationId,
      if (connectionId != null) 'connectionId': connectionId,
      if (tenantLookupIdentifier != null) 'tenantLookupIdentifier': tenantLookupIdentifier,
      if (additionalParams != null) ...additionalParams,
    };

    final response = await _httpService.post(
      '/api/authentication',
      body: requestBody,
    );

    if (!response.isSuccess) {
      throw Exception(
        'Failed to get authentication URL: ${response.statusCode} ${response.body}',
      );
    }

    final authenticationUrl =
        response.jsonBody['authenticationUrl'] as String?;
    final authenticationRequestId =
        response.jsonBody['authenticationRequestId'] as String?;

    if (authenticationUrl == null || authenticationRequestId == null) {
      throw Exception(
        'Authress response missing authenticationUrl or authenticationRequestId',
      );
    }

    return AuthenticationStartResult(
      authenticationUrl: authenticationUrl,
      authenticationRequestId: authenticationRequestId,
      redirectUrl: redirectUrl,
      codeVerifier: pkceCodes.codeVerifier,
    );
  }

  /// Exchange authorization code for tokens
  Future<void> _exchangeCodeForTokens(String code, String nonce) async {
    final pending = await _tokenService.loadPendingAuth();
    final codeVerifier = pending?['codeVerifier'] as String?;
    final redirectUrl =
        pending?['redirectUrl'] as String? ?? _resolveRedirectUrl();
    final storedNonce = pending?['nonce'] as String?;

    if (codeVerifier == null) {
      throw Exception(
        'Code verifier not found - authentication flow corrupted',
      );
    }

    if (storedNonce != null && storedNonce != nonce) {
      throw Exception('Authentication nonce mismatch');
    }

    final antiAbuseHash = await _cryptoService.calculateAntiAbuseHash({
      'client_id': _config.applicationId,
      'authenticationRequestId': nonce,
      'code': code,
    });

    final requestBody = {
      'grant_type': 'authorization_code',
      'redirect_uri': redirectUrl,
      'client_id': _config.applicationId,
      'code': code,
      'code_verifier': codeVerifier,
      'antiAbuseHash': antiAbuseHash,
    };

    final response = await _httpService.post(
      '/api/authentication/$nonce/tokens',
      body: requestBody,
    );

    if (!response.isSuccess) {
      throw Exception(
        'Token exchange failed: ${response.statusCode} ${response.body}',
      );
    }

    await _processTokenResponse(response.jsonBody);
  }

  /// Process token response and update state
  Future<void> _processTokenResponse(Map<String, dynamic> data) async {
    final accessToken = data['access_token'] as String;
    final idToken = data['id_token'] as String;
    final refreshToken = data['refresh_token'] as String?;
    final expiresIn = data['expires_in'] as int? ?? 3600;

    final payload = _tokenService.parseJwtPayload(idToken);
    if (payload == null) {
      throw Exception('Invalid ID token received');
    }

    final userProfile = UserProfile.fromJson(payload);
    final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

    await _tokenService.storeTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      userProfile: userProfile,
      expiresAt: expiresAt,
    );

    final authState = AuthStateAuthenticated(
      user: userProfile,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
    );

    _setState(authState);
    _scheduleTokenRefresh(expiresAt);
  }

  /// Attempt to refresh tokens
  Future<bool> _attemptTokenRefresh() async {
    final storedAuth = await _tokenService.loadStoredTokens();
    if (storedAuth?.refreshToken == null) return false;

    try {
      final response = await _httpService.post(
        '/v1/clients/${_config.applicationId}/oauth/tokens',
        body: {
          'grant_type': 'refresh_token',
          'client_id': _config.applicationId,
          'refresh_token': storedAuth!.refreshToken!,
        },
      );

      if (!response.isSuccess) return false;

      await _processTokenResponse(response.jsonBody);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Schedule automatic token refresh
  void _scheduleTokenRefresh(DateTime expiresAt) {
    _tokenService.scheduleTokenRefresh(expiresAt, _attemptTokenRefresh);
  }

  /// Logout current user
  Future<void> logout() async {
    if (!kIsWeb) {
      _deepLinkService.cancelAuthFlow();
    }
    await _tokenService.clearPendingAuth();
    await _tokenService.clearTokens();
    _setState(const AuthStateUnauthenticated());
  }

  /// Ensure we have a valid access token
  Future<String?> ensureValidToken() async {
    final currentState = _state;
    if (currentState is! AuthStateAuthenticated) return null;

    if (currentState.isTokenExpired || currentState.willExpireSoon) {
      final refreshed = await _attemptTokenRefresh();
      if (!refreshed) return null;

      final updatedState = _state;
      return updatedState is AuthStateAuthenticated ? updatedState.accessToken : null;
    }

    return currentState.accessToken;
  }

  /// Get user profile from API
  Future<UserProfile?> fetchUserProfile() async {
    final token = await ensureValidToken();
    if (token == null) return null;

    try {
      final response = await _httpService.get(
        '/v1/users/me',
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.isSuccess) {
        return UserProfile.fromJson(response.jsonBody);
      }
    } catch (e) {}

    return null;
  }

  /// Update internal state and notify listeners
  void _setState(AuthState newState) {
    if (_state != newState) {
      _state = newState;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _tokenService.dispose();
    _httpService.dispose();
    _deepLinkService.dispose();
    super.dispose();
  }
}
