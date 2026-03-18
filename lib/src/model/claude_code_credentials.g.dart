// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'claude_code_credentials.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ShortLivedClaudeCodeCredentials _$ShortLivedClaudeCodeCredentialsFromJson(
  Map<String, dynamic> json,
) => ShortLivedClaudeCodeCredentials(
  accessToken: json['access_token'] as String,
  refreshToken: json['refresh_token'] as String,
  expiresAt: const _DateTimeConverter().fromJson(
    (ClaudeCodeCredentials._readExpiresAt(json, 'expires_at') as num).toInt(),
  ),
  tokenType: json['token_type'] as String? ?? 'Bearer',
);

Map<String, dynamic> _$ShortLivedClaudeCodeCredentialsToJson(
  ShortLivedClaudeCodeCredentials instance,
) => <String, dynamic>{
  'token_type': instance.tokenType,
  'access_token': instance.accessToken,
  'refresh_token': instance.refreshToken,
  'expires_at': const _DateTimeConverter().toJson(instance.expiresAt),
};

LongLivedClaudeCodeCredentials _$LongLivedClaudeCodeCredentialsFromJson(
  Map<String, dynamic> json,
) => LongLivedClaudeCodeCredentials(
  accessToken: json['access_token'] as String,
  expiresAt: const _DateTimeConverter().fromJson(
    (ClaudeCodeCredentials._readExpiresAt(json, 'expires_at') as num).toInt(),
  ),
  tokenType: json['token_type'] as String? ?? 'Bearer',
);

Map<String, dynamic> _$LongLivedClaudeCodeCredentialsToJson(
  LongLivedClaudeCodeCredentials instance,
) => <String, dynamic>{
  'token_type': instance.tokenType,
  'access_token': instance.accessToken,
  'expires_at': const _DateTimeConverter().toJson(instance.expiresAt),
};
