import 'dart:convert';
import 'dart:typed_data';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:meta/meta.dart';
import 'package:openai_dart/openai_dart.dart';

import '../converters/request/chat_completion_request_converter.dart';
import '../converters/response/chat_completion_response_converter.dart';
import '../converters/streaming/stream_event_transformer.dart';

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
class AnthropicOpenAIClient extends OpenAIClient {
  late final anthropic.AnthropicClient _anthropicClient;
  final ChatCompletionRequestConverter _requestConverter;
  final ChatCompletionResponseConverter _responseConverter;

  final int _anthropicRetries;

  int get anthropicRetries => _anthropicRetries;

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
    super.apiKey,
    super.baseUrl = 'https://api.anthropic.com/v1',
    super.headers,
    super.queryParams,
    super.retries,
    http.Client? client,
  }) : _anthropicRetries = retries,
       _requestConverter = ChatCompletionRequestConverter(),
       _responseConverter = ChatCompletionResponseConverter(),
       super(client: client != null ? RetryClient(client, retries: retries) : null) {
    _anthropicClient = buildAnthropicClient();
  }

  @protected
  anthropic.AnthropicClient buildAnthropicClient() => anthropic.AnthropicClient(
    apiKey: apiKey,
    baseUrl: baseUrl,
    headers: headers,
    queryParams: queryParams,
    retries: _anthropicRetries,
    client: client,
  );

  /// Creates a chat completion.
  ///
  /// This method converts the OpenAI request format to Anthropic format,
  /// calls the Anthropic API, and converts the response back to OpenAI format.
  ///
  /// Note: Some OpenAI parameters are not supported by Anthropic and will be
  /// logged as warnings. The response will include `provider: 'anthropic'` to
  /// indicate which provider processed the request.
  @override
  Future<CreateChatCompletionResponse> createChatCompletion({required CreateChatCompletionRequest request}) async {
    // Get the model ID for the response
    final requestModel = request.model.map(model: (m) => m.value.toString(), modelId: (m) => m.value);

    // Convert OpenAI request to Anthropic request
    final anthropicRequest = _requestConverter.convert(request);

    // Call Anthropic API
    final anthropicResponse = await _anthropicClient.createMessage(request: anthropicRequest);

    // Convert Anthropic response to OpenAI response
    return _responseConverter.convert(anthropicResponse, requestModel);
  }

  /// Creates a streaming chat completion.
  ///
  /// This method converts the OpenAI request format to Anthropic format,
  /// streams responses from the Anthropic API, and transforms each event
  /// to OpenAI's streaming format.
  ///
  /// Example:
  /// ```dart
  /// final stream = client.createChatCompletionStream(
  ///   request: CreateChatCompletionRequest(
  ///     model: ChatCompletionModel.modelId('claude-sonnet-4-20250514'),
  ///     messages: [...],
  ///   ),
  /// );
  ///
  /// await for (final chunk in stream) {
  ///   print(chunk.choices.first.delta?.content ?? '');
  /// }
  /// ```
  @override
  Stream<CreateChatCompletionStreamResponse> createChatCompletionStream({
    required CreateChatCompletionRequest request,
  }) async* {
    // Get the model ID for the response
    final requestModel = request.model.map(model: (m) => m.value.toString(), modelId: (m) => m.value);

    // Convert OpenAI request to Anthropic request
    final anthropicRequest = _requestConverter.convert(request);

    // Create the stream transformer
    final transformer = StreamEventTransformer(requestModel: requestModel);

    // Call Anthropic streaming API and transform events
    yield* _anthropicClient.createMessageStream(request: anthropicRequest).transform(transformer);
  }

  /// Closes the HTTP client and ends the session.
  @override
  void endSession() {
    _anthropicClient.endSession();
    super.endSession();
  }

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
  ///
  /// Example:
  /// ```dart
  /// final result = await client.createDocumentCompletion(
  ///   systemPrompt: 'You are a document parser.',
  ///   userPrompt: 'Extract the key information from this document.',
  ///   documentBytes: pdfBytes,
  ///   documentMediaType: 'application/pdf',
  ///   outputSchema: {'type': 'object', 'properties': {...}},
  ///   outputToolName: 'extract_info',
  ///   outputToolDescription: 'Extracts structured information from the document',
  /// );
  /// ```
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
    final contentBlocks = <anthropic.Block>[
      anthropic.Block.text(text: userPrompt),
      anthropic.Block.document(
        type: 'document',
        source: anthropic.DocumentBlockSource.base64PdfSource(
          type: 'base64',
          mediaType: anthropic.Base64PdfSourceMediaType.applicationPdf,
          data: documentBase64,
        ),
        title: documentFileName,
      ),
    ];

    // Create the tool for structured output
    final outputTool = anthropic.Tool.custom(
      name: outputToolName,
      description: outputToolDescription,
      inputSchema: outputSchema,
    );

    // Build the request
    final request = anthropic.CreateMessageRequest(
      model: anthropic.Model.modelId(model),
      maxTokens: maxTokens,
      system: systemPrompt != null ? anthropic.CreateMessageRequestSystem.text(systemPrompt) : null,
      messages: [
        anthropic.Message(
          role: anthropic.MessageRole.user,
          content: anthropic.MessageContent.blocks(contentBlocks),
        ),
      ],
      tools: [outputTool],
      toolChoice: anthropic.ToolChoice(
        type: anthropic.ToolChoiceType.tool,
        name: outputToolName,
      ),
    );

    // Call the API
    final response = await _anthropicClient.createMessage(request: request);

    // Extract the structured output from the tool call
    final blocks = response.content.map(
      blocks: (b) => b.value,
      text: (_) => <anthropic.Block>[],
    );

    for (final block in blocks) {
      final toolUse = block.mapOrNull(toolUse: (t) => t);
      if (toolUse != null && toolUse.name == outputToolName) {
        return toolUse.input;
      }
    }

    throw StateError(
      'No structured output found in response. '
      'Expected tool call to "$outputToolName" but got: ${response.content}',
    );
  }

  // ============================================================================
  // Unsupported Methods
  // ============================================================================
  // The following methods are part of the OpenAI API but cannot be translated
  // to Anthropic equivalents. They throw UnsupportedError when called.

  /// Not supported - Anthropic does not have an embeddings API.
  @override
  Future<CreateEmbeddingResponse> createEmbedding({required CreateEmbeddingRequest request}) {
    throw UnsupportedError(
      'createEmbedding is not supported by Anthropic. '
      'Consider using a dedicated embedding service.',
    );
  }

  /// Not supported - Anthropic does not have a completions API (legacy).
  @override
  Future<CreateCompletionResponse> createCompletion({required CreateCompletionRequest request}) {
    throw UnsupportedError(
      'createCompletion is not supported by Anthropic. '
      'Use createChatCompletion instead.',
    );
  }

  /// Not supported - Anthropic does not have a completions API (legacy).
  @override
  Stream<CreateCompletionResponse> createCompletionStream({required CreateCompletionRequest request}) {
    throw UnsupportedError(
      'createCompletionStream is not supported by Anthropic. '
      'Use createChatCompletionStream instead.',
    );
  }

  /// Not supported - Anthropic does not have an image generation API.
  @override
  Future<ImagesResponse> createImage({required CreateImageRequest request}) {
    throw UnsupportedError(
      'createImage is not supported by Anthropic. '
      'Consider using a dedicated image generation service.',
    );
  }

  /// Not supported - Anthropic does not have a models listing API.
  @override
  Future<ListModelsResponse> listModels() {
    throw UnsupportedError(
      'listModels is not supported by Anthropic. '
      'Refer to Anthropic documentation for available models.',
    );
  }

  /// Not supported - Anthropic does not have a model retrieval API.
  @override
  Future<Model> retrieveModel({required String model}) {
    throw UnsupportedError(
      'retrieveModel is not supported by Anthropic. '
      'Refer to Anthropic documentation for model information.',
    );
  }

  /// Not supported - Anthropic does not have a fine-tuning API.
  @override
  Future<FineTuningJob> createFineTuningJob({required CreateFineTuningJobRequest request}) {
    throw UnsupportedError('createFineTuningJob is not supported by Anthropic.');
  }

  /// Not supported - Anthropic does not have a moderation API.
  @override
  Future<CreateModerationResponse> createModeration({required CreateModerationRequest request}) {
    throw UnsupportedError(
      'createModeration is not supported by Anthropic. '
      'Consider using a dedicated content moderation service.',
    );
  }

  /// Not supported - Anthropic does not have an assistants API.
  @override
  Future<AssistantObject> createAssistant({required CreateAssistantRequest request}) {
    throw UnsupportedError('Assistants API is not supported by Anthropic.');
  }

  /// Not supported - Anthropic does not have a threads API.
  @override
  Future<ThreadObject> createThread({CreateThreadRequest? request}) {
    throw UnsupportedError('Threads API is not supported by Anthropic.');
  }
}
