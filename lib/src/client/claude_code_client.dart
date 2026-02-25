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
/// interface as OpenAI's SDK. Simply provide your Anthropic API key and use
/// the client as you would use `OpenAIClient`.
///
/// Example:
/// ```dart
/// final client = ClaudeCodeOpenAIClient(credentials: 'your-claude-code-credentials');
///
/// final response = await client.createChatCompletion(
///   request: CreateChatCompletionRequest(
///     model: ChatCompletionModel.modelId('claude-sonnet-4-20250514'),
///     messages: [
///       ChatCompletionMessage.user(
///         content: ChatCompletionUserMessageContent.string('Hello!'),
///       ),
///     ],
///   ),
/// );
/// ```
class ClaudeCodeOpenAIClient extends AnthropicOpenAIClient {
  final ClaudeCodeTokenStore _tokenStore;
  final bool debugLogNetworkRequests;

  ClaudeCodeCredentials get credentials => _tokenStore.credentials;

  static const String anthropicBeta =
      'oauth-2025-04-20,claude-code-20250219,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14';

  /// Creates a new ClaudeCodeOpenAIClient.
  ClaudeCodeOpenAIClient({
    ClaudeCodeCredentials? credentials,
    ClaudeCodeTokenStore? tokenStore,
    super.baseUrl,
    super.headers,
    super.queryParams,
    super.retries = 3,
    TokenRefreshedCallback? onTokenRefreshed,
    this.debugLogNetworkRequests = false,
  }) : assert(credentials != null || tokenStore != null, 'Either credentials or tokenStore must be provided.'),
       _tokenStore = tokenStore ?? ClaudeCodeTokenStore(credentials!, onTokenRefreshedCallback: onTokenRefreshed),
       super(apiKey: '');

  @override
  anthropic.AnthropicClient buildAnthropicClient() => AnthropicAuthenticatedClient(
    tokenStore: _tokenStore,
    baseUrl: anthropicBaseUrl,
    headers: anthropicHeaders,
    queryParams: anthropicQueryParams,
    retries: anthropicRetries,
    debugLogNetworkRequests: debugLogNetworkRequests,
  );
}

class AnthropicAuthenticatedClient extends anthropic.AnthropicClient {
  final ClaudeCodeTokenStore tokenStore;
  final bool debugLogNetworkRequests;

  late final http.Client _authenticatedClient = InterceptedClient.build(
    interceptors: [
      _AnthropicAuthInterceptor(tokenStore: tokenStore),
      if (debugLogNetworkRequests) LoggerInterceptor(),
    ],
  );

  @override
  http.Client get client => _authenticatedClient;

  AnthropicAuthenticatedClient({
    super.baseUrl,
    super.headers,
    super.queryParams,
    super.retries,
    required this.tokenStore,
    super.client,
    this.debugLogNetworkRequests = false,
  }) : super(apiKey: ''); // API key not used, OAuth handled in interceptor.

  @override
  Future<BaseRequest> onRequest(BaseRequest request) async =>
      request.copyWith(headers: await _injectHeaders(tokenStore, request.headers));

  static Future<Map<String, String>> _injectHeaders(
    ClaudeCodeTokenStore tokenStore,
    Map<String, String> headers,
  ) async {
    return {
        ...headers,
        'Authorization': 'Bearer ${await tokenStore.getAccessToken()}',
        // 'anthropic-beta': 'oauth-2025-04-20',
        // 'content-type': 'text/plain; charset=utf-8',
        'anthropic-beta': ClaudeCodeOpenAIClient.anthropicBeta,
      }
      ..remove('accept')
      ..remove('x-api-key');
  }
}

class _AnthropicAuthInterceptor implements InterceptorContract {
  final ClaudeCodeTokenStore tokenStore;

  _AnthropicAuthInterceptor({required this.tokenStore});

  @override
  FutureOr<BaseRequest> interceptRequest({required BaseRequest request}) async {
    return request.copyWith(headers: await AnthropicAuthenticatedClient._injectHeaders(tokenStore, request.headers));
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
