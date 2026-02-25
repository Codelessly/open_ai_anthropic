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
    if (_credentials.isExpired) {
      final newCredentials = await refresh();
      await onTokenRefreshed(newCredentials);
      return newCredentials.accessToken;
    }
    return _credentials.accessToken;
  }

  /// Refresh access token using refresh token
  Future<ClaudeCodeCredentials> refresh() async {
    final response = await _client.post(
      Uri.parse('https://console.anthropic.com/v1/oauth/token'),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://claude.ai/',
        'Origin': 'https://claude.ai',
      },
      body: jsonEncode({
        'grant_type': 'refresh_token',
        'client_id': '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
        'refresh_token': _credentials.refreshToken,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Token refresh failed: ${response.body}');
    }

    final Map<String, dynamic> tokens = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    tokens['expires_at'] = DateTime.timestamp().add(Duration(seconds: tokens['expires_in'])).millisecondsSinceEpoch;
    return ClaudeCodeCredentials.fromJson(tokens);
  }

  @mustCallSuper
  Future<void> onTokenRefreshed(ClaudeCodeCredentials newCredentials) async {
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
      log('⚠️ Failed to save refreshed tokens to file: $error\n$stackTrace');
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
