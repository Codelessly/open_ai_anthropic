import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:json_annotation/json_annotation.dart';

import '../open_ai_anthropic.dart';

part 'oauth_service.g.dart';

class ClaudeCodeOauthService {
  final http.Client httpClient;

  final ClaudeCodeOAuthConfig config = const ClaudeCodeOAuthConfig();

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
  String _getAuthorizationUrl(String codeChallenge, String state, String? redirectUri) {
    final uri = Uri.parse(config.authorizeUrl);
    final updatedUri = uri.replace(
      queryParameters: {
        'code': 'true', // Tell it to return code
        'client_id': config.clientId,
        'redirect_uri': redirectUri ?? config.redirectUri,
        'response_type': 'code',
        'scope': config.scope,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'state': state,
      },
    );
    return updatedUri.toString();
  }

  /// Exchange authorization code for tokens
  Future<TokenExchangeResponse> _exchangeCodeForTokens({
    required String code,
    required String codeVerifier,
    required String state,
    required String redirectUri,
    Map<String, dynamic>? extraBodyParams,
  }) async {
    if (code.contains('#')) {
      code = code.split('#').elementAtOrNull(0)?.split('&').elementAtOrNull(0) ?? code;
    }

    final response = await http.post(
      Uri.parse(config.tokenUrl),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'grant_type': 'authorization_code',
        'client_id': config.clientId,
        'code': code,
        'state': state,
        'redirect_uri': redirectUri,
        'code_verifier': codeVerifier,
        ...?extraBodyParams,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Token exchange failed: ${response.body}');
    }

    final Map<String, dynamic> tokens = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    tokens['expires_at'] = DateTime.timestamp().add(Duration(seconds: tokens['expires_in'])).millisecondsSinceEpoch;
    return TokenExchangeResponse.fromJson(tokens);
  }

  /// Refresh access token using refresh token
  static Future<ShortLivedClaudeCodeCredentials> refreshAccessToken(
    String refreshToken, {
    ClaudeCodeOAuthConfig? config,
  }) async {
    config ??= const ClaudeCodeOAuthConfig();
    final response = await http.post(
      Uri.parse(config.tokenUrl),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'grant_type': 'refresh_token',
        'client_id': config.clientId,
        'refresh_token': refreshToken,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Token refresh failed. status=${response.statusCode}; '
        'url=${config.tokenUrl}; body=${response.body}',
      );
    }

    final Map<String, dynamic> tokens = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    tokens['expires_at'] = DateTime.timestamp().add(Duration(seconds: tokens['expires_in'])).millisecondsSinceEpoch;
    return ShortLivedClaudeCodeCredentials.fromJson(tokens);
  }

  ClaudeCodeOAuthRequest prepareOAuthRequest({String? redirectionUri}) {
    final pkce = _generatePKCE();
    final state = _generateState();
    final authUrl = _getAuthorizationUrl(pkce['challenge']!, state, redirectionUri);
    return (verifier: pkce['verifier']!, state: state, authUrl: authUrl);
  }

  Future<TokenExchangeResponse> completeOAuthFlow({
    required ClaudeCodeOAuthRequest request,
    required String authCode,
    String? redirectionUri,
    bool longLivedToken = true,
  }) async {
    print('🔄 Exchanging code for tokens...\n');

    if (authCode.contains('#')) {
      // Some browsers append fragments after #
      authCode = authCode.split('#').first;
    }

    return await _exchangeCodeForTokens(
      code: authCode,
      codeVerifier: request.verifier,
      state: request.state,
      redirectUri: redirectionUri ?? config.redirectUri,
      extraBodyParams: longLivedToken
          ? {
              'expires_in': 31536000, // 1 year in seconds, to get a long-lived token.
            }
          : null,
    );
  }
}

typedef ClaudeCodeOAuthRequest = ({String verifier, String state, String authUrl});

class ClaudeCodeOAuthConfig {
  const ClaudeCodeOAuthConfig();

  final String clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
  final String authorizeUrl = "https://claude.ai/oauth/authorize"; // MAX mode
  final String tokenUrl = "https://platform.claude.com/v1/oauth/token";
  final String redirectUri = "https://platform.claude.com/oauth/code/callback";

  // Scopes must match pi-mono's SCOPES constant.
  // Source: https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/utils/oauth/anthropic.ts
  final String scope = "user:inference user:file_upload";
}

@JsonSerializable(fieldRename: FieldRename.snake)
class TokenExchangeResponse {
  /// Usually Bearer
  final String tokenType;
  final String accessToken;
  final String refreshToken;

  /// In seconds. Usually 8 hours.
  final int expiresIn;
  final String scope;
  final AnthropicOrganization organization;
  final AnthropicAccount account;
  @DateTimeConverter()
  final DateTime expiresAt;

  TokenExchangeResponse({
    required this.tokenType,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.scope,
    required this.organization,
    required this.account,
    required this.expiresAt,
  });

  factory TokenExchangeResponse.fromJson(Map<String, dynamic> json) => _$TokenExchangeResponseFromJson(json);

  Map<String, dynamic> toJson() => _$TokenExchangeResponseToJson(this);
}

@JsonSerializable(fieldRename: FieldRename.snake)
class AnthropicOrganization {
  final String uuid;
  final String name;

  AnthropicOrganization({required this.uuid, required this.name});

  factory AnthropicOrganization.fromJson(Map<String, dynamic> json) => _$AnthropicOrganizationFromJson(json);

  Map<String, dynamic> toJson() => _$AnthropicOrganizationToJson(this);
}

@JsonSerializable(fieldRename: FieldRename.snake)
class AnthropicAccount {
  final String uuid;
  @JsonKey(name: 'email_address')
  final String email;

  AnthropicAccount({required this.uuid, required this.email});

  factory AnthropicAccount.fromJson(Map<String, dynamic> json) => _$AnthropicAccountFromJson(json);

  Map<String, dynamic> toJson() => _$AnthropicAccountToJson(this);
}

/// Top level converter for serializing [DateTime] to [millisecondsSinceEpoch].
class DateTimeConverter extends JsonConverter<DateTime, int> {
  /// Creates a new instance of [DateTimeConverter].
  const DateTimeConverter();

  @override
  DateTime fromJson(int json) => deserialize(json);

  @override
  int toJson(DateTime object) => serialize(object);

  /// Serializes [DateTime] to [int].
  static int serialize(DateTime object) => object.toUtc().millisecondsSinceEpoch;

  /// Deserializes [int] to [DateTime].
  static DateTime deserialize(int json) {
    return DateTime.fromMillisecondsSinceEpoch(json, isUtc: true).toLocal();
  }
}
