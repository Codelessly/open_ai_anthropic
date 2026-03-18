import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';

part 'claude_code_credentials.g.dart';

/// Represents OAuth2 credentials for Claude Code API.
/// This is used to authenticate requests to the Claude Code service using
/// access token instead of API key.
sealed class ClaudeCodeCredentials {
  /// The type of the token, typically "Bearer".
  String get tokenType;

  /// OAuth2 access token.
  String get accessToken;

  /// Epoch milliseconds when the token expires.
  /// Derived from 'expires_in' or directly from 'expires_at' in the JSON.
  DateTime get expiresAt;

  /// Whether the access token is expired.
  bool get isExpired;

  /// Converts this [ClaudeCodeCredentials] instance to JSON map.
  Map<String, dynamic> toJson();

  /// Creates the appropriate [ClaudeCodeCredentials] subtype from a JSON string.
  /// Uses the presence of a non-empty `refresh_token` field to determine the subtype.
  static ClaudeCodeCredentials fromJsonString(String jsonString) {
    final json = jsonDecode(jsonString);
    if (json is! Map) {
      throw FormatException('Invalid JSON format for ClaudeCredentials');
    }
    final map = Map<String, dynamic>.from(json);
    if (map.containsKey('refresh_token') &&
        (map['refresh_token'] as String?)?.isNotEmpty == true) {
      return ShortLivedClaudeCodeCredentials.fromJson(map);
    }
    return LongLivedClaudeCodeCredentials.fromJson(map);
  }

  /// Creates the appropriate [ClaudeCodeCredentials] subtype from a JSON map.
  /// Uses the presence of a non-empty `refresh_token` field to determine the subtype.
  static ClaudeCodeCredentials fromJson(Map<String, dynamic> json) {
    if (json.containsKey('refresh_token') &&
        (json['refresh_token'] as String?)?.isNotEmpty == true) {
      return ShortLivedClaudeCodeCredentials.fromJson(json);
    }
    return LongLivedClaudeCodeCredentials.fromJson(json);
  }

  /// Custom JSON reader for 'expires_at' field.
  /// Handles different formats: int (epoch ms), String (ISO 8601), or derives from 'expires_in'.
  /// If neither is present, returns null.
  ///
  /// When OAuth flow returns access token response, it includes `expires_in` field.
  /// This function calculates the `expires_at` based on current time plus `expires_in` seconds.
  /// If `expires_at` is already provided, it uses that directly.
  static int? _readExpiresAt(Map json, String key) {
    return switch (json[key]) {
      int value => value,
      String value => DateTime.parse(value).toUtc().millisecondsSinceEpoch,
      null => switch (json['expires_in']) {
        int value => DateTime.timestamp()
            .add(Duration(seconds: value))
            .toUtc()
            .millisecondsSinceEpoch,
        String value when int.tryParse(value) != null => DateTime.timestamp()
            .add(Duration(seconds: int.parse(value)))
            .toUtc()
            .millisecondsSinceEpoch,
        _ => null,
      },
      _ => null,
    };
  }
}

/// Short-lived OAuth2 credentials that include a refresh token.
/// These credentials expire and can be refreshed using the [refreshToken].
@JsonSerializable(fieldRename: FieldRename.snake)
class ShortLivedClaudeCodeCredentials extends ClaudeCodeCredentials {
  @override
  final String tokenType;

  @override
  final String accessToken;

  /// OAuth2 refresh token.
  /// Used to obtain a new access token when the current one expires.
  final String refreshToken;

  @override
  @JsonKey(readValue: ClaudeCodeCredentials._readExpiresAt)
  @_DateTimeConverter()
  final DateTime expiresAt;

  /// Whether the access token is expired.
  /// Includes a buffer to proactively refresh tokens before they actually expire.
  @override
  bool get isExpired =>
      expiresAt.toUtc().difference(DateTime.timestamp()) <= expirationBuffer;

  Duration get expirationBuffer => Duration(minutes: 5);

  /// Creates a new [ShortLivedClaudeCodeCredentials] instance.
  ShortLivedClaudeCodeCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.tokenType = 'Bearer',
  });

  /// Creates a new [ShortLivedClaudeCodeCredentials] instance from JSON map.
  factory ShortLivedClaudeCodeCredentials.fromJson(Map<String, dynamic> json) =>
      _$ShortLivedClaudeCodeCredentialsFromJson(json);

  @override
  Map<String, dynamic> toJson() =>
      _$ShortLivedClaudeCodeCredentialsToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShortLivedClaudeCodeCredentials &&
          accessToken == other.accessToken &&
          refreshToken == other.refreshToken &&
          tokenType == other.tokenType &&
          expiresAt == other.expiresAt;

  @override
  int get hashCode => Object.hash(accessToken, refreshToken, tokenType, expiresAt);

  @override
  String toString() =>
      'ShortLivedClaudeCodeCredentials(accessToken: ${accessToken.substring(0, accessToken.length.clamp(0, 4))}****, refreshToken: ${refreshToken.substring(0, refreshToken.length.clamp(0, 4))}****, expiresAt: $expiresAt)';
}

/// Long-lived OAuth2 credentials that do not include a refresh token.
/// These credentials have a simple expiration check with no buffer.
@JsonSerializable(fieldRename: FieldRename.snake)
class LongLivedClaudeCodeCredentials extends ClaudeCodeCredentials {
  @override
  final String tokenType;

  @override
  final String accessToken;

  @override
  @JsonKey(readValue: ClaudeCodeCredentials._readExpiresAt)
  @_DateTimeConverter()
  final DateTime expiresAt;

  /// Whether the access token is expired.
  /// Simple check with no proactive buffer.
  @override
  bool get isExpired => expiresAt.toUtc().isBefore(DateTime.timestamp());

  /// Creates a new [LongLivedClaudeCodeCredentials] instance.
  LongLivedClaudeCodeCredentials({
    required this.accessToken,
    required this.expiresAt,
    this.tokenType = 'Bearer',
  });

  /// Creates a new [LongLivedClaudeCodeCredentials] instance from JSON map.
  factory LongLivedClaudeCodeCredentials.fromJson(Map<String, dynamic> json) =>
      _$LongLivedClaudeCodeCredentialsFromJson(json);

  @override
  Map<String, dynamic> toJson() =>
      _$LongLivedClaudeCodeCredentialsToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LongLivedClaudeCodeCredentials &&
          accessToken == other.accessToken &&
          tokenType == other.tokenType &&
          expiresAt == other.expiresAt;

  @override
  int get hashCode => Object.hash(accessToken, tokenType, expiresAt);

  @override
  String toString() =>
      'LongLivedClaudeCodeCredentials(accessToken: ${accessToken.substring(0, accessToken.length.clamp(0, 4))}****, expiresAt: $expiresAt)';
}

class _DateTimeConverter implements JsonConverter<DateTime, int> {
  const _DateTimeConverter();

  @override
  DateTime fromJson(int json) =>
      DateTime.fromMillisecondsSinceEpoch(json, isUtc: true);

  @override
  int toJson(DateTime object) => object.toUtc().millisecondsSinceEpoch;
}
