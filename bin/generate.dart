import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

Future<void> main() async {
  try {
    final service = ClaudeCodeOauthService();
    final redirectionPort = 10738;
    final redirectionUri = 'http://localhost:$redirectionPort/callback';
    final request = service.prepareOAuthRequest(redirectionUri: redirectionUri);

    final Completer<String> authCodeCompleter = Completer<String>();

    final server = await startRedirectionServer(authCodeCompleter, port: redirectionPort, endpoint: '/callback');

    print('\n🔐 Starting OAuth flow...\n');
    print('Please visit this URL to authorize:\n');
    print(request.authUrl);
    print('\n${'=' * 70}');
    print('After authorizing, if not auto redirected, copy the authorization code and paste it here:');
    print('=' * 70 + '\n');

    StreamSubscription? sub;
    sub = LineSplitter().bind(stdin.transform(utf8.decoder)).listen((data) {
      final code = data.trim();
      if (code.isNotEmpty) {
        authCodeCompleter.complete(code);
      }
    });

    final code = await authCodeCompleter.future;
    await Future.delayed(Duration(seconds: 1));
    await sub.cancel();
    await server.close(force: true);

    final credentials = await service.completeOAuthFlow(
      request: request,
      authCode: code,
      redirectionUri: redirectionUri,
    );

    // Write to a file!
    // File('claude_code_credentials.json').writeAsStringSync(JsonEncoder.withIndent('  ').convert(credentials.toJson()));

    final credentialsString = JsonEncoder.withIndent('  ').convert(credentials);
    File('claude_code_credentials.json').writeAsStringSync(credentialsString);

    print('✅ Token exchange successful!\n');
    print(credentialsString);
    print('✅ Done! Use these credentials to authenticate your requests to the ClaudeCodeClient.');
  } catch (e) {
    print('❌ Error: $e');
  }
}

Future<HttpServer> startRedirectionServer(
  Completer<String> authCodeCompleter, {
  required int port,
  required String endpoint,
}) async {
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);

  print('Redirection server running on http://localhost:$port');
  server.listen((request) async {
    final path = request.uri.path;

    if(path.isEmpty || path == '/') {
      // Just respond with a simple page for root requests
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(
          '''
          <html>
            <body style="font-family: Arial, sans-serif; text-align: center; padding: 50px;">
              <h1>OAuth Redirection Server</h1>
              <p>This server is used to capture the authorization code from the OAuth flow.</p>
            </body>
          </html>
          ''',
        );
      await request.response.close();
      return;
    }

    if (path == endpoint) {
      final queryParams = request.uri.queryParameters;
      final code = queryParams['code'];
      final state = queryParams['state'];

      if (code == null || state == null) {
        // return Response(400, body: 'Missing code or state');
        request.response
          ..statusCode = 400
          ..headers.contentType = ContentType.html
          ..write(
            '''
            <html>
              <body style="font-family: Arial, sans-serif; text-align: center; padding: 50px;">
                <h1>Authorization Failed</h1>
                <p>Missing code or state in the callback.</p>
              </body>
            </html>
            ''',
          );
        await request.response.close();
        return;
      }

      // In a real app, you'd verify the state matches what you originally sent
      print('Received auth code: $code');
      print('Received state: $state');

      // Respond to the browser immediately with message in HTML.
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(
          '''
          <html>
            <body style="font-family: Arial, sans-serif; text-align: center; padding: 50px;">
              <h1>Authorization Successful!</h1>
              <p>You can now close this window.</p>
            </body>
          </html>
          ''',
        );
      await request.response.close();
      authCodeCompleter.complete(code);
    }
  });

  return server;
}

class ClaudeCodeOauthService {
  final http.Client httpClient;

  ClaudeCodeOauthService({http.Client? httpClient}) : httpClient = httpClient ?? http.Client();

  /// Generate PKCE code verifier and challenge
  Map<String, String> _generatePKCE() {
    final randomBytes = Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)));
    // RFC 7636 requires base64url encoding WITHOUT padding
    final verifier = base64UrlEncode(randomBytes).replaceAll('=', '');
    final challenge = base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    return {'verifier': verifier, 'challenge': challenge};
  }

  /// Generate random state for CSRF protection
  String _generateState() {
    final randomBytes = Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)));
    return base64UrlEncode(randomBytes).replaceAll('=', '');
  }

  /// Build authorization URL for OAuth flow
  String _getAuthorizationUrl(String codeChallenge, String state, {String? redirectionUri}) {
    final uri = Uri.parse(ClaudeOAuthConfig.authorizeUrl);
    final updatedUri = uri.replace(
      queryParameters: {
        'code': 'true', // Tell it to return code
        'client_id': ClaudeOAuthConfig.clientId,
        'redirect_uri': redirectionUri ?? ClaudeOAuthConfig.redirectUri,
        'response_type': 'code',
        'scope': ClaudeOAuthConfig.scope,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'state': state,
      },
    );
    return updatedUri.toString();
  }

  /// Exchange authorization code for tokens
  Future<Map<String, dynamic>> _exchangeCodeForTokens(
    String code,
    String codeVerifier,
    String state, {
    String? redirectionUri,
  }) async {
    final cleanedCode = code.split('#').elementAtOrNull(0)?.split('&').elementAtOrNull(0) ?? code;

    final Map<String, String> bodyJson = {
      'code': cleanedCode,
      'state': state,
      'grant_type': 'authorization_code',
      'client_id': ClaudeOAuthConfig.clientId,
      'redirect_uri': redirectionUri ?? ClaudeOAuthConfig.redirectUri,
      'code_verifier': codeVerifier,
    };
    final response = await httpClient.post(
      Uri.parse(ClaudeOAuthConfig.tokenUrl),
      headers: ClaudeOAuthConfig.defaultHeaders,
      body: jsonEncode(bodyJson),
    );

    if (response.statusCode != 200) {
      throw Exception('Token exchange failed: ${response.body}');
    }

    final Map<String, dynamic> tokens = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    tokens['expires_at'] = DateTime.timestamp().add(Duration(seconds: tokens['expires_in'])).millisecondsSinceEpoch;
    return tokens;
  }

  /// Refresh access token using refresh token
  static Future<Map<String, dynamic>> refreshAccessToken(String refreshToken) async {
    final response = await http.post(
      Uri.parse(ClaudeOAuthConfig.tokenUrl),
      headers: ClaudeOAuthConfig.defaultHeaders,
      body: jsonEncode({
        'grant_type': 'refresh_token',
        'client_id': ClaudeOAuthConfig.clientId,
        'refresh_token': refreshToken,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Token refresh failed: ${response.body}');
    }

    final Map<String, dynamic> tokens = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    tokens['expires_at'] = DateTime.timestamp().add(Duration(seconds: tokens['expires_in'])).millisecondsSinceEpoch;
    return tokens;
  }

  ClaudeCodeOAuthRequest prepareOAuthRequest({String? redirectionUri}) {
    final pkce = _generatePKCE();
    final state = _generateState();
    final authUrl = _getAuthorizationUrl(pkce['challenge']!, state, redirectionUri: redirectionUri);
    return (verifier: pkce['verifier']!, state: state, authUrl: authUrl);
  }

  Future<Map<String, dynamic>> completeOAuthFlow({
    required ClaudeCodeOAuthRequest request,
    required String authCode,
    String? redirectionUri,
  }) async {
    print('🔄 Exchanging code for tokens...\n');

    if (authCode.contains('#')) {
      // Some browsers append fragments after #
      authCode = authCode.split('#').first;
    }

    return await _exchangeCodeForTokens(
      authCode,
      request.verifier,
      request.state,
      redirectionUri: redirectionUri,
    );
  }
}

typedef ClaudeCodeOAuthRequest = ({String verifier, String state, String authUrl});

abstract class ClaudeOAuthConfig {
  static const String clientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
  static const String authorizeUrl = 'https://claude.ai/oauth/authorize'; // MAX mode
  static const String tokenUrl = 'https://console.anthropic.com/v1/oauth/token';
  static const String redirectUri = 'https://console.anthropic.com/oauth/code/callback';

  static const String scope = 'org:create_api_key user:profile user:inference';
  static const String anthropicBeta =
      'oauth-2025-04-20,claude-code-20250219,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14';

  static const Map<String, String> defaultHeaders = {
    'Content-Type': 'application/json',
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': 'https://claude.ai/',
    'Origin': 'https://claude.ai',
  };
}
