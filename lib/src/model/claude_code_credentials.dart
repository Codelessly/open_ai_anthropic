import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';

part 'claude_code_credentials.g.dart';

/// Represents OAuth2 credentials for Claude Code API.
/// This is used to authenticate requests to the Claude Code service using
/// access token instead of API key.
@JsonSerializable(fieldRename: FieldRename.snake)
class ClaudeCodeCredentials {
  /// The type of the token, typically "Bearer".
  final String tokenType;

  /// OAuth2 access token.
  final String accessToken;

  /// OAuth2 refresh token.
  /// Used to obtain a new access token when the current one expires.
  final String refreshToken;

  /// Epoch milliseconds when the token expires.
  /// Derived from 'expires_in' or directly from 'expires_at' in the JSON.
  @JsonKey(readValue: _readExpiresAt)
  @_DateTimeConverter()
  final DateTime expiresAt;

  /// Whether the access token is expired.
  /// Includes a buffer to proactively refresh tokens before they actually expire.
  bool get isExpired => DateTime.timestamp().difference(expiresAt) <= expirationBuffer;

  Duration get expirationBuffer => Duration(minutes: 5);

  /// Creates a new [ClaudeCodeCredentials] instance.
  const ClaudeCodeCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.tokenType = 'Bearer',
  });

  factory ClaudeCodeCredentials.fromToken(
    String token, {
    String tokenType = 'Bearer',
    String? refreshToken,
    DateTime? expiresAt,
  }) => ClaudeCodeCredentials(
    accessToken: token,
    refreshToken: refreshToken ?? '',
    expiresAt: expiresAt ?? DateTime.timestamp().add(Duration(hours: 1)),
    tokenType: tokenType,
  );

  /// Custom JSON reader for 'expires_at' field.
  /// Handles different formats: int (epoch ms), String (ISO 8601), or derives from 'expires_in'.
  /// If neither is present, returns null.
  /// Used in the JsonKey annotation above for [expiresAt].
  ///
  /// When OAuth flow returns access token response, it includes `expires_in` field.
  /// This function calculates the `expires_at` based on current time plus `expires_in` seconds.
  /// If `expires_at` is already provided, it uses that directly.
  static int? _readExpiresAt(Map json, String key) {
    return switch (json[key]) {
      int value => value,
      String value => DateTime.parse(value).toUtc().millisecondsSinceEpoch,
      null => switch (json['expires_in']) {
        int value => DateTime.timestamp().add(Duration(seconds: value)).toUtc().millisecondsSinceEpoch,
        String value when int.tryParse(value) != null =>
          DateTime.timestamp().add(Duration(seconds: int.parse(value))).toUtc().millisecondsSinceEpoch,
        _ => null,
      },
      _ => null,
    };
  }

  /// Creates a new [ClaudeCodeCredentials] instance from JSON map.
  factory ClaudeCodeCredentials.fromJson(Map<String, dynamic> json) => _$ClaudeCodeCredentialsFromJson(json);

  /// Creates a new [ClaudeCodeCredentials] instance from JSON string.
  factory ClaudeCodeCredentials.fromJsonString(String jsonString) {
    final json = jsonDecode(jsonString);
    if (json is! Map) throw FormatException('Invalid JSON format for ClaudeCredentials');
    return ClaudeCodeCredentials.fromJson(Map<String, dynamic>.from(json));
  }

  /// Converts this [ClaudeCodeCredentials] instance to JSON map.
  Map<String, dynamic> toJson() => _$ClaudeCodeCredentialsToJson(this);

  @override
  String toString() =>
      'ClaudeCodeCredentials(accessToken: ${accessToken.substring(0, 4)}****, refreshToken: ${refreshToken.substring(0, 4)}****, expiresAt: $expiresAt)';
}

class _DateTimeConverter implements JsonConverter<DateTime, int> {
  const _DateTimeConverter();

  @override
  DateTime fromJson(int json) => DateTime.fromMillisecondsSinceEpoch(json, isUtc: true);

  @override
  int toJson(DateTime object) => object.toUtc().millisecondsSinceEpoch;
}
