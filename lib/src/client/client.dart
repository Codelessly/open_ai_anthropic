import 'dart:convert';
import 'dart:typed_data';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:openai_dart/openai_dart.dart';
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:openai_dart/src/client/request_builder.dart';

import '../converters/request/chat_completion_request_converter.dart';
import '../converters/response/chat_completion_response_converter.dart';
import '../converters/streaming/stream_event_transformer.dart';

/// Callback that receives the Anthropic request body as a mutable JSON map
/// before it is sent to the API. Use this to apply cache breakpoints or
/// other provider-specific mutations.
typedef BodyTransformer = void Function(Map<String, dynamic> body);

/// Cache retention policy for Anthropic prompt caching.
enum CacheRetention {
  /// No caching — cache_control is omitted entirely.
  none,

  /// Short-lived cache (default). Uses `{type: "ephemeral"}`.
  short,

  /// Long-lived cache. Uses `{type: "ephemeral", ttl: "1h"}` on api.anthropic.com.
  long,
}

/// A client that exposes OpenAI's API interface but uses Anthropic's Claude models.
///
/// This client extends [OpenAIClient] and can be used as a drop-in replacement
/// anywhere an [OpenAIClient] is expected. It translates OpenAI API calls to
/// Anthropic's Claude API.
///
/// Example:
/// ```dart
/// final client = AnthropicOpenAIClient(apiKey: 'your-anthropic-api-key');
///
/// final response = await client.chat.completions.create(
///   ChatCompletionCreateRequest(
///     model: 'claude-sonnet-4-20250514',
///     messages: [ChatMessage.user('Hello!')],
///   ),
/// );
/// ```
class AnthropicOpenAIClient extends OpenAIClient {
  late final anthropic.AnthropicClient _anthropicClient;
  final ChatCompletionRequestConverter _requestConverter;
  final ChatCompletionResponseConverter _responseConverter;
  final http.Client? _ownHttpClient;
  late final http.Client _resourceHttpClient;

  final String _apiKey;
  final String _baseUrl;
  final Map<String, String> _headers;
  final Map<String, dynamic> _queryParams;
  final int _retries;

  /// Whether this client uses OAuth authentication (Claude Code mode).
  /// When true, enables Claude Code compatibility in request conversion.
  final bool isOAuth;

  /// Optional callback to mutate the Anthropic request body before sending.
  final BodyTransformer? bodyTransformer;

  /// Optional callback that receives the Anthropic response body (as JSON)
  /// after each **non-streaming** API call. Use this to extract
  /// provider-specific fields like `cache_creation_input_tokens` that have
  /// no OpenAI equivalent.
  ///
  /// For streaming, these fields are available directly on each chunk's
  /// `toJson()['usage']` output instead.
  final BodyTransformer? responseBodyTransformer;

  /// The Anthropic API key.
  String get apiKey => _apiKey;

  /// The base URL for the Anthropic API.
  String get baseUrl => _baseUrl;

  /// Additional headers to send with every request.
  Map<String, String> get headers => _headers;

  /// Query parameters to send with every request.
  Map<String, dynamic> get queryParams => _queryParams;

  /// Number of retries for failed requests.
  int get anthropicRetries => _retries;

  /// Creates a new AnthropicOpenAIClient.
  ///
  /// Parameters:
  /// - [apiKey]: Your Anthropic API key.
  /// - [baseUrl]: Optional custom base URL for the Anthropic API.
  /// - [headers]: Optional additional headers to send with every request.
  /// - [queryParams]: Optional query parameters to send with every request.
  /// - [retries]: Number of retries for failed requests (default: 3).
  /// - [client]: Optional custom HTTP client.
  AnthropicOpenAIClient({
    String apiKey = '',
    String baseUrl = 'https://api.anthropic.com/v1',
    Map<String, String> headers = const {},
    Map<String, dynamic> queryParams = const {},
    int retries = 3,
    http.Client? client,
    this.isOAuth = false,
    this.bodyTransformer,
    this.responseBodyTransformer,
  }) : _apiKey = apiKey,
       _baseUrl = baseUrl,
       _headers = headers,
       _queryParams = queryParams,
       _retries = retries,
       _ownHttpClient = client,
       _requestConverter = ChatCompletionRequestConverter(),
       _responseConverter = ChatCompletionResponseConverter(),
       super(httpClient: client) {
    _resourceHttpClient = client ?? http.Client();
    _anthropicClient = buildAnthropicClient();
  }

  /// Strips the `/v1` path segment from a base URL if present, since the new
  /// SDK constructs resource paths (e.g. `/v1/messages`) internally.
  static String normalizeAnthropicBaseUrl(String? baseUrl) {
    final url = baseUrl ?? 'https://api.anthropic.com';
    return url.endsWith('/v1') ? url.substring(0, url.length - 3) : url.replaceAll(RegExp(r'/v1/?$'), '');
  }

  @protected
  anthropic.AnthropicClient buildAnthropicClient() {
    return anthropic.AnthropicClient(
      config: anthropic.AnthropicConfig(
        authProvider: _apiKey.isNotEmpty ? anthropic.ApiKeyProvider(_apiKey) : null,
        baseUrl: normalizeAnthropicBaseUrl(_baseUrl),
        defaultHeaders: _headers,
        defaultQueryParams: _queryParams.map((k, v) => MapEntry(k, '$v')),
        retryPolicy: anthropic.RetryPolicy(maxRetries: _retries),
      ),
      httpClient: _ownHttpClient,
    );
  }

  // ============================================================================
  // Override chat resource to route through Anthropic
  // ============================================================================

  _AnthropicChatResource? _anthropicChat;

  @override
  ChatResource get chat => _anthropicChat ??= _AnthropicChatResource(
    anthropicClient: _anthropicClient,
    requestConverter: _requestConverter,
    responseConverter: _responseConverter,
    isOAuth: isOAuth,
    bodyTransformer: bodyTransformer,
    responseBodyTransformer: responseBodyTransformer,
    // These base resource fields are required by the parent class but unused
    // since our overridden create()/createStream() bypass OpenAI's HTTP pipeline.
    config: config,
    httpClient: _resourceHttpClient,
    interceptorChain: interceptorChain,
    requestBuilder: RequestBuilder(config: config),
  );

  /// Creates a chat completion with document input and structured JSON output.
  ///
  /// This method is specifically designed for use cases that require:
  /// 1. Document input (e.g., PDF files) which are not supported by OpenAI API
  /// 2. Structured JSON output via tool calling
  ///
  /// Parameters:
  /// - [systemPrompt]: The system prompt to guide the model's behavior
  /// - [userPrompt]: The user's text prompt
  /// - [documentBytes]: The document content as bytes (e.g., PDF)
  /// - [documentMediaType]: The MIME type of the document (e.g., 'application/pdf')
  /// - [documentFileName]: Optional filename for the document
  /// - [outputSchema]: JSON schema defining the expected output structure
  /// - [outputToolName]: Name of the tool that will capture the structured output
  /// - [outputToolDescription]: Description of the tool's purpose
  /// - [model]: The Claude model to use (defaults to claude-sonnet-4-20250514)
  /// - [maxTokens]: Maximum tokens in the response (defaults to 8192)
  ///
  /// Returns a Map containing the structured output matching the provided schema.
  Future<Map<String, dynamic>> createDocumentCompletion({
    String? systemPrompt,
    required String userPrompt,
    required Uint8List documentBytes,
    required String documentMediaType,
    String? documentFileName,
    required Map<String, dynamic> outputSchema,
    required String outputToolName,
    required String outputToolDescription,
    String model = 'claude-sonnet-4-20250514',
    int maxTokens = 8192,
  }) async {
    // Convert document bytes to base64
    final documentBase64 = base64Encode(documentBytes);

    // Build the message content with text and document
    final contentBlocks = <anthropic.InputContentBlock>[
      anthropic.InputContentBlock.text(userPrompt),
      anthropic.InputContentBlock.document(
        anthropic.DocumentSource.base64Pdf(documentBase64),
        title: documentFileName,
      ),
    ];

    // Create the tool for structured output
    final outputTool = anthropic.ToolDefinition.custom(
      anthropic.Tool(
        name: outputToolName,
        description: outputToolDescription,
        inputSchema: anthropic.InputSchema(
          type: outputSchema['type'] as String? ?? 'object',
          properties: outputSchema['properties'] as Map<String, dynamic>?,
          required: (outputSchema['required'] as List?)?.cast<String>(),
        ),
      ),
    );

    // Build the request
    final request = anthropic.MessageCreateRequest(
      model: model,
      maxTokens: maxTokens,
      system: systemPrompt != null ? anthropic.SystemPrompt.text(systemPrompt) : null,
      messages: [
        anthropic.InputMessage.userBlocks(contentBlocks),
      ],
      tools: [outputTool],
      toolChoice: anthropic.ToolChoice.tool(outputToolName),
    );

    // Call the API
    final response = await _anthropicClient.messages.create(request);

    // Extract the structured output from the tool call
    final toolUse = response.toolUseBlocks.where((b) => b.name == outputToolName).firstOrNull;
    if (toolUse != null) return toolUse.input;

    throw StateError(
      'No structured output found in response. '
      'Expected tool call to "$outputToolName" but got: ${response.content}',
    );
  }

  /// Closes the underlying Anthropic client.
  @override
  void close() {
    _anthropicClient.close();
    if (_ownHttpClient == null) {
      _resourceHttpClient.close();
    }
    super.close();
  }
}

// ============================================================================
// Internal resource classes to intercept chat completions
// ============================================================================

class _AnthropicChatResource extends ChatResource {
  final anthropic.AnthropicClient anthropicClient;
  final ChatCompletionRequestConverter requestConverter;
  final ChatCompletionResponseConverter responseConverter;
  final bool isOAuth;
  final BodyTransformer? bodyTransformer;
  final BodyTransformer? responseBodyTransformer;

  _AnthropicChatResource({
    required this.anthropicClient,
    required this.requestConverter,
    required this.responseConverter,
    this.isOAuth = false,
    this.bodyTransformer,
    this.responseBodyTransformer,
    required super.config,
    required super.httpClient,
    required super.interceptorChain,
    required super.requestBuilder,
  });

  _AnthropicChatCompletionsResource? _anthropicCompletions;

  @override
  ChatCompletionsResource get completions => _anthropicCompletions ??= _AnthropicChatCompletionsResource(
    anthropicClient: anthropicClient,
    requestConverter: requestConverter,
    responseConverter: responseConverter,
    isOAuth: isOAuth,
    bodyTransformer: bodyTransformer,
    responseBodyTransformer: responseBodyTransformer,
    config: config,
    httpClient: httpClient,
    interceptorChain: interceptorChain,
    requestBuilder: requestBuilder,
  );
}

class _AnthropicChatCompletionsResource extends ChatCompletionsResource {
  final anthropic.AnthropicClient anthropicClient;
  final ChatCompletionRequestConverter requestConverter;
  final ChatCompletionResponseConverter responseConverter;
  final bool isOAuth;
  final BodyTransformer? bodyTransformer;
  final BodyTransformer? responseBodyTransformer;

  _AnthropicChatCompletionsResource({
    required this.anthropicClient,
    required this.requestConverter,
    required this.responseConverter,
    this.isOAuth = false,
    this.bodyTransformer,
    this.responseBodyTransformer,
    required super.config,
    required super.httpClient,
    required super.interceptorChain,
    required super.requestBuilder,
  });

  @override
  Future<ChatCompletion> create(
    ChatCompletionCreateRequest request, {
    Future<void>? abortTrigger,
  }) async {
    final requestModel = request.model;
    final anthropicRequest = requestConverter.convert(request, bodyTransformer: bodyTransformer, isOAuth: isOAuth);
    final anthropicResponse = await anthropicClient.messages.create(anthropicRequest);
    final originalToolNames = isOAuth
        ? request.tools?.map((t) => t.function.name).toList()
        : null;
    final converted = responseConverter.convert(
      anthropicResponse,
      requestModel,
      isOAuth: isOAuth,
      originalToolNames: originalToolNames,
    );

    if (responseBodyTransformer != null) {
      try {
        final json = converted.toJson();
        responseBodyTransformer!(json);
      } catch (_) {
        // Don't let a transformer error swallow a successful API response.
      }
    }

    return converted.completion;
  }

  @override
  Stream<ChatStreamEvent> createStream(
    ChatCompletionCreateRequest request, {
    Future<void>? abortTrigger,
  }) {
    final requestModel = request.model;
    final anthropicRequest = requestConverter.convert(request, bodyTransformer: bodyTransformer, isOAuth: isOAuth);
    final transformer = StreamEventTransformer(requestModel: requestModel);
    return anthropicClient.messages.createStream(anthropicRequest).transform(transformer);
  }
}
