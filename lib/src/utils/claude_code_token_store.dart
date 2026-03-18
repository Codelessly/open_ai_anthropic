import 'dart:convert';
import 'dart:developer';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:universal_io/io.dart';

import '../model/claude_code_credentials.dart';

typedef TokenRefreshedCallback = Future<void> Function(ClaudeCodeCredentials newCredentials);

class ClaudeCodeTokenStore {
  ClaudeCodeCredentials _credentials;
  final http.Client _client;

  final TokenRefreshedCallback? onTokenRefreshedCallback;

  ClaudeCodeTokenStore(
    this._credentials, {
    http.Client? client,
    this.onTokenRefreshedCallback,
  }) : _client = client ?? http.Client();

  ClaudeCodeCredentials get credentials => _credentials;

  static FileClaudeCodeTokenStore createFromFileSync(
    String filePath, {
    http.Client? client,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    bool autoSave = true,
  }) => FileClaudeCodeTokenStore.createSync(
    filePath,
    autoSave: autoSave,
    onTokenRefreshedCallback: onTokenRefreshedCallback,
    client: client,
  );

  static FileClaudeCodeTokenStore? tryCreateFromFileSync(
    String filePath, {
    http.Client? client,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    bool autoSave = true,
  }) {
    try {
      return FileClaudeCodeTokenStore.createSync(
        filePath,
        autoSave: autoSave,
        onTokenRefreshedCallback: onTokenRefreshedCallback,
        client: client,
      );
    } catch (e) {
      return null;
    }
  }

  static Future<FileClaudeCodeTokenStore> createFromFile(
    String filePath, {
    http.Client? client,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    bool autoSave = true,
  }) => FileClaudeCodeTokenStore.create(
    filePath,
    autoSave: autoSave,
    onTokenRefreshedCallback: onTokenRefreshedCallback,
    client: client,
  );

  static Future<FileClaudeCodeTokenStore?> tryCreateFromFile(
    String filePath, {
    http.Client? client,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    bool autoSave = true,
  }) async {
    try {
      return await FileClaudeCodeTokenStore.create(
        filePath,
        autoSave: autoSave,
        onTokenRefreshedCallback: onTokenRefreshedCallback,
        client: client,
      );
    } catch (e) {
      return null;
    }
  }

  static SystemClaudeCodeTokenStore createFromSystemSync({
    http.Client? client,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    bool autoSave = true,
  }) => SystemClaudeCodeTokenStore.createSync(
    autoSave: autoSave,
    onTokenRefreshedCallback: onTokenRefreshedCallback,
    client: client,
  );

  static SystemClaudeCodeTokenStore? tryCreateFromSystemSync({
    http.Client? client,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    bool autoSave = true,
  }) {
    try {
      return SystemClaudeCodeTokenStore.createSync(
        autoSave: autoSave,
        onTokenRefreshedCallback: onTokenRefreshedCallback,
        client: client,
      );
    } catch (e) {
      return null;
    }
  }

  static Future<SystemClaudeCodeTokenStore> createFromSystem({
    http.Client? client,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    bool autoSave = true,
  }) => SystemClaudeCodeTokenStore.create(
    autoSave: autoSave,
    onTokenRefreshedCallback: onTokenRefreshedCallback,
    client: client,
  );

  static Future<SystemClaudeCodeTokenStore?> tryCreateFromSystem({
    http.Client? client,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    bool autoSave = true,
  }) async {
    try {
      return await SystemClaudeCodeTokenStore.create(
        autoSave: autoSave,
        onTokenRefreshedCallback: onTokenRefreshedCallback,
        client: client,
      );
    } catch (e) {
      return null;
    }
  }

  @protected
  set credentials(ClaudeCodeCredentials newCredentials) {
    _credentials = newCredentials;
  }

  @mustCallSuper
  Future<String> getAccessToken() async {
    return switch (_credentials) {
      ShortLivedClaudeCodeCredentials creds when creds.isExpired => (await refresh()).accessToken,
      LongLivedClaudeCodeCredentials creds when creds.isExpired => throw StateError(
        'Long-lived credentials have expired and cannot be refreshed.',
      ),
      _ => _credentials.accessToken,
    };
  }

  /// Refresh access token using refresh token.
  /// Only works with [ShortLivedClaudeCodeCredentials]. Throws if called
  /// on [LongLivedClaudeCodeCredentials].
  ///
  /// Replicates pi-mono's `refreshAnthropicToken` verbatim:
  /// - POST to TOKEN_URL with only { grant_type, client_id, refresh_token }.
  /// - Headers: only Content-Type + Accept (no browser-like headers).
  /// - Scope is explicitly omitted from refresh requests.
  /// - Expiry: subtracts 5-minute safety buffer from expires_in.
  /// Source: https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/utils/oauth/anthropic.ts
  Future<ClaudeCodeCredentials> refresh() async {
    if (_credentials is! ShortLivedClaudeCodeCredentials) {
      throw StateError(
        'Cannot refresh long-lived credentials. '
        'Only ShortLivedClaudeCodeCredentials support token refresh.',
      );
    }
    final shortLived = _credentials as ShortLivedClaudeCodeCredentials;

    const tokenUrl = 'https://platform.claude.com/v1/oauth/token';
    final response = await _client.post(
      Uri.parse(tokenUrl),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'grant_type': 'refresh_token',
        'client_id': '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
        'refresh_token': shortLived.refreshToken,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Token refresh failed. status=${response.statusCode}; '
        'url=$tokenUrl; body=${response.body}',
      );
    }

    final Map<String, dynamic> tokens = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    tokens['expires_at'] = DateTime.timestamp().add(Duration(seconds: tokens['expires_in'])).millisecondsSinceEpoch;
    final newCredentials = ClaudeCodeCredentials.fromJson(tokens);
    await onTokenRefreshed(newCredentials);
    return newCredentials;
  }

  @mustCallSuper
  Future<void> onTokenRefreshed(ClaudeCodeCredentials newCredentials) async {
    onTokenRefreshedCallback?.call(newCredentials);
    _credentials = newCredentials;
  }
}

class FileClaudeCodeTokenStore extends ClaudeCodeTokenStore {
  final String filePath;
  final bool autoSave;

  FileClaudeCodeTokenStore(
    super.credentials, {
    required this.filePath,
    this.autoSave = true,
    super.onTokenRefreshedCallback,
    super.client,
  });

  factory FileClaudeCodeTokenStore.createSync(
    String filePath, {
    bool autoSave = true,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    http.Client? client,
  }) {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw Exception('Token file not found: $filePath');
    }
    final content = file.readAsStringSync();
    final credentials = ClaudeCodeCredentials.fromJsonString(content);
    return FileClaudeCodeTokenStore(
      credentials,
      filePath: filePath,
      autoSave: autoSave,
      onTokenRefreshedCallback: onTokenRefreshedCallback,
      client: client,
    );
  }

  static FileClaudeCodeTokenStore? tryCreateSync(
    String filePath, {
    bool autoSave = true,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    http.Client? client,
  }) {
    try {
      return FileClaudeCodeTokenStore.createSync(
        filePath,
        autoSave: autoSave,
        onTokenRefreshedCallback: onTokenRefreshedCallback,
        client: client,
      );
    } catch (e) {
      return null;
    }
  }

  static Future<FileClaudeCodeTokenStore> create(
    String filePath, {
    bool autoSave = true,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    http.Client? client,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Token file not found: $filePath');
    }
    final content = await file.readAsString();
    final credentials = ClaudeCodeCredentials.fromJsonString(content);
    return FileClaudeCodeTokenStore(
      credentials,
      filePath: filePath,
      autoSave: autoSave,
      onTokenRefreshedCallback: onTokenRefreshedCallback,
      client: client,
    );
  }

  static Future<FileClaudeCodeTokenStore?> tryCreate(
    String filePath, {
    bool autoSave = true,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    http.Client? client,
  }) async {
    try {
      return await FileClaudeCodeTokenStore.create(
        filePath,
        autoSave: autoSave,
        onTokenRefreshedCallback: onTokenRefreshedCallback,
        client: client,
      );
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> onTokenRefreshed(ClaudeCodeCredentials newCredentials) async {
    await super.onTokenRefreshed(newCredentials);
    if (!autoSave) return;
    final file = File(filePath);
    final json = jsonEncode(newCredentials.toJson());
    try {
      await file.writeAsString(json);
    } catch (error, stackTrace) {
      log('Failed to save refreshed tokens to file', stackTrace: stackTrace, error: error);
    }
  }
}

class SystemClaudeCodeTokenStore extends FileClaudeCodeTokenStore {
  static String _getFilePath() {
    if (Platform.isMacOS || Platform.isLinux) {
      return '${Platform.environment['HOME']}/.claude/.credentials.json';
    } else if (Platform.isWindows) {
      return '${Platform.environment['USERPROFILE']}\\.claude\\.credentials.json';
    } else {
      throw Exception('Unsupported platform: ${Platform.operatingSystem}');
    }
  }

  SystemClaudeCodeTokenStore(
    super.credentials, {
    super.autoSave,
    super.onTokenRefreshedCallback,
    super.client,
  }) : super(filePath: _getFilePath());

  factory SystemClaudeCodeTokenStore.createSync({
    bool autoSave = true,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    http.Client? client,
  }) {
    final file = File(_getFilePath());
    if (!file.existsSync()) {
      throw Exception('Token file not found: ${_getFilePath()}');
    }
    final content = file.readAsStringSync();
    final credentials = ClaudeCodeCredentials.fromJsonString(content);
    return SystemClaudeCodeTokenStore(
      credentials,
      autoSave: autoSave,
      onTokenRefreshedCallback: onTokenRefreshedCallback,
      client: client,
    );
  }

  static SystemClaudeCodeTokenStore? tryCreateSync({
    bool autoSave = true,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    http.Client? client,
  }) {
    try {
      return SystemClaudeCodeTokenStore.createSync(
        autoSave: autoSave,
        onTokenRefreshedCallback: onTokenRefreshedCallback,
        client: client,
      );
    } catch (e) {
      return null;
    }
  }

  static Future<SystemClaudeCodeTokenStore> create({
    bool autoSave = true,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    http.Client? client,
  }) async {
    final file = File(_getFilePath());
    if (!await file.exists()) {
      throw Exception('Token file not found: ${_getFilePath()}');
    }
    final content = await file.readAsString();
    final credentials = ClaudeCodeCredentials.fromJsonString(content);
    return SystemClaudeCodeTokenStore(
      credentials,
      autoSave: autoSave,
      onTokenRefreshedCallback: onTokenRefreshedCallback,
      client: client,
    );
  }

  static Future<SystemClaudeCodeTokenStore?> tryCreate({
    bool autoSave = true,
    TokenRefreshedCallback? onTokenRefreshedCallback,
    http.Client? client,
  }) async {
    try {
      return await SystemClaudeCodeTokenStore.create(
        autoSave: autoSave,
        onTokenRefreshedCallback: onTokenRefreshedCallback,
        client: client,
      );
    } catch (e) {
      return null;
    }
  }
}
