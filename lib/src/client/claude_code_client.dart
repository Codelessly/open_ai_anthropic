import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:http/http.dart' as http;
import 'package:http_interceptor/http_interceptor.dart';

import '../model/claude_code_credentials.dart';
import '../utils/claude_code_token_store.dart';
import 'client.dart';

/// An anthropic client that uses Claude Code OAuth instead of an API key.
///
/// This client allows you to use Anthropic's Claude models with the same API
/// interface as OpenAI's SDK. Simply provide your Claude Code credentials and use
/// the client as you would use `OpenAIClient`.
///
/// Example:
/// ```dart
/// final client = ClaudeCodeOpenAIClient(credentials: credentials);
///
/// final response = await client.chat.completions.create(
///   ChatCompletionCreateRequest(
///     model: 'claude-sonnet-4-20250514',
///     messages: [ChatMessage.user('Hello!')],
///   ),
/// );
/// ```
class ClaudeCodeOpenAIClient extends AnthropicOpenAIClient {
  final ClaudeCodeTokenStore _tokenStore;
  final bool debugLogNetworkRequests;

  /// Whether to include the `context-1m-2025-08-07` beta header for 1M
  /// context window access.
  ///
  /// Reference: claude-code/src/utils/betas.ts line 254 + context.ts lines 35-39
  ///   Claude Code adds this header when the model ID contains `[1m]`
  ///   (e.g. `claude-opus-4-6[1m]`). It's the only beta API key users can
  ///   pass via SDK options.
  final bool use1mContext;

  ClaudeCodeCredentials get credentials => _tokenStore.credentials;

  /// The `context-1m-2025-08-07` beta header value.
  /// Ref: claude-code/src/constants/betas.ts line 6
  static const String context1mBetaHeader = 'context-1m-2025-08-07';

  /// Default beta header for non-model-specific use (includes all betas).
  /// Includes effort-2025-11-24 required for output_config.effort to function.
  static const String anthropicBeta =
      'oauth-2025-04-20,claude-code-20250219,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14,effort-2025-11-24';

  /// Builds the anthropic-beta header value for a specific model.
  /// For 4.6 models (adaptive thinking), omits the deprecated
  /// interleaved-thinking beta header (#15).
  /// Always includes effort-2025-11-24 for output_config.effort support.
  ///
  /// If [use1mContext] is true, appends the `context-1m-2025-08-07` header.
  /// Ref: claude-code/src/utils/betas.ts lines 254-256
  static String buildBetaHeader(String modelId, {bool use1mContext = false}) {
    final betas = [
      'claude-code-20250219',
      'oauth-2025-04-20',
      'fine-grained-tool-streaming-2025-05-14',
      'effort-2025-11-24',
    ];
    final needsInterleavedBeta =
        !modelId.contains('opus-4-6') &&
        !modelId.contains('opus-4.6') &&
        !modelId.contains('sonnet-4-6') &&
        !modelId.contains('sonnet-4.6');
    if (needsInterleavedBeta) {
      betas.add('interleaved-thinking-2025-05-14');
    }
    if (use1mContext) {
      betas.add(context1mBetaHeader);
    }
    return betas.join(',');
  }

  /// Creates a new ClaudeCodeOpenAIClient.
  ///
  /// Set [use1mContext] to `true` to include the `context-1m-2025-08-07` beta
  /// header, enabling 1M token context window. Defaults to `false` (200K).
  ClaudeCodeOpenAIClient({
    ClaudeCodeCredentials? credentials,
    ClaudeCodeTokenStore? tokenStore,
    super.baseUrl,
    super.headers,
    super.queryParams,
    super.retries = 3,
    super.bodyTransformer,
    super.responseBodyTransformer,
    TokenRefreshedCallback? onTokenRefreshed,
    this.debugLogNetworkRequests = false,
    this.use1mContext = false,
  }) : assert(credentials != null || tokenStore != null, 'Either credentials or tokenStore must be provided.'),
       _tokenStore = tokenStore ?? ClaudeCodeTokenStore(credentials!, onTokenRefreshedCallback: onTokenRefreshed),
       super(apiKey: '', isOAuth: true);

  /// The resolved beta header string for this client instance.
  String get resolvedBetaHeader =>
      use1mContext ? '$anthropicBeta,$context1mBetaHeader' : anthropicBeta;

  @override
  anthropic.AnthropicClient buildAnthropicClient() => AnthropicAuthenticatedClient(
    tokenStore: _tokenStore,
    baseUrl: baseUrl,
    headers: headers,
    queryParams: queryParams,
    retries: anthropicRetries,
    debugLogNetworkRequests: debugLogNetworkRequests,
    betaHeader: resolvedBetaHeader,
  );
}

class AnthropicAuthenticatedClient extends anthropic.AnthropicClient {
  static http.Client _buildAuthenticatedClient(
    ClaudeCodeTokenStore tokenStore,
    String betaHeader,
    bool debug,
  ) => InterceptedClient.build(
    interceptors: [
      _AnthropicAuthInterceptor(tokenStore: tokenStore, betaHeader: betaHeader),
      if (debug) LoggerInterceptor(),
    ],
  );

  AnthropicAuthenticatedClient({
    String? baseUrl,
    Map<String, String>? headers,
    Map<String, dynamic>? queryParams,
    int retries = 3,
    required ClaudeCodeTokenStore tokenStore,
    bool debugLogNetworkRequests = false,
    String betaHeader = ClaudeCodeOpenAIClient.anthropicBeta,
  }) : super(
         config: anthropic.AnthropicConfig(
           // OAuth handles auth — no API key header should be added.
           authProvider: const anthropic.NoAuthProvider(),
           baseUrl: AnthropicOpenAIClient.normalizeAnthropicBaseUrl(baseUrl),
           defaultHeaders: {
             ...?headers,
           },
           defaultQueryParams: queryParams?.map((k, v) => MapEntry(k, '$v')) ?? const {},
           retryPolicy: anthropic.RetryPolicy(maxRetries: retries),
         ),
         httpClient: _buildAuthenticatedClient(tokenStore, betaHeader, debugLogNetworkRequests),
       );

  /// Injects the necessary authentication headers into the request.
  /// Matches pi-mono's OAuth client construction for Claude Code compatibility.
  static Future<Map<String, String>> _injectHeaders(
    ClaudeCodeTokenStore tokenStore,
    String betaHeader,
    Map<String, String> headers,
  ) async {
    return {
        ...headers,
        'Authorization': 'Bearer ${await tokenStore.getAccessToken()}',
        'anthropic-beta': betaHeader,
        'user-agent': 'claude-cli/2.1.75',
        'x-app': 'cli',
        'accept': 'application/json',
        'anthropic-dangerous-direct-browser-access': 'true',
      }
      // Critical: ensure 'x-api-key' is not sent, as it will cause authentication to fail.
      ..remove('x-api-key');
  }
}

class _AnthropicAuthInterceptor implements InterceptorContract {
  final ClaudeCodeTokenStore tokenStore;
  final String betaHeader;

  _AnthropicAuthInterceptor({required this.tokenStore, required this.betaHeader});

  @override
  FutureOr<BaseRequest> interceptRequest({required BaseRequest request}) async {
    return request.copyWith(
      headers: await AnthropicAuthenticatedClient._injectHeaders(
        tokenStore,
        betaHeader,
        request.headers,
      ),
    );
  }

  @override
  FutureOr<BaseResponse> interceptResponse({required BaseResponse response}) async => response;

  @override
  FutureOr<bool> shouldInterceptRequest() => true;

  @override
  FutureOr<bool> shouldInterceptResponse() => false;
}

class LoggerInterceptor extends InterceptorContract {
  @override
  Future<BaseRequest> interceptRequest({required BaseRequest request}) async {
    print('-' * 80);
    print('REQUEST: $request');
    print('-' * 80);
    _printHeaders(request.headers);
    print('-' * 80);
    final updated = request.copyWith();
    final stream = request.finalize();
    Uint8List bodyBytes = await stream.toBytes();
    final bodyString = utf8.decode(bodyBytes);
    print('BODY:');
    if (request.headers[HttpHeaders.contentTypeHeader]?.contains('application/json') == true) {
      final json = jsonDecode(bodyString);
      if (json != null) {
        print(const JsonEncoder.withIndent('  ').convert(json));
      } else {
        print(bodyString);
      }
    } else {
      print(bodyString);
    }
    return updated;
  }

  @override
  Future<BaseResponse> interceptResponse({required BaseResponse response}) async {
    print('-' * 80);
    print('RESPONSE: ${response.statusCode} ${response.request}');
    print('-' * 80);
    _printHeaders(response.headers);
    if (response case Response(:final body)) {
      print('BODY:');
      if (response.headers[HttpHeaders.contentTypeHeader]?.contains('application/json') == true) {
        final json = jsonDecode(body);
        if (json != null) {
          print(const JsonEncoder.withIndent('  ').convert(json));
        } else {
          print(body);
        }
      } else {
        print(body);
      }
    }
    print('-' * 80);
    return response;
  }

  void _printHeaders(Map<String, String> headers) {
    print('HEADERS:');
    final maxKeyLength = headers.keys.fold(0, (maxLength, e) => max(e.length, maxLength));
    final entries = [...headers.entries]..sort((a, b) => a.key.compareTo(b.key));
    for (var entry in entries) {
      print('${entry.key.padRight(maxKeyLength)} : ${entry.value}');
    }
  }
}
