// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'claude_code_credentials.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ClaudeCodeCredentials _$ClaudeCodeCredentialsFromJson(
  Map<String, dynamic> json,
) => ClaudeCodeCredentials(
  accessToken: json['access_token'] as String,
  refreshToken: json['refresh_token'] as String,
  expiresAt: const _DateTimeConverter().fromJson(
    (ClaudeCodeCredentials._readExpiresAt(json, 'expires_at') as num).toInt(),
  ),
  tokenType: json['token_type'] as String? ?? 'Bearer',
);

Map<String, dynamic> _$ClaudeCodeCredentialsToJson(
  ClaudeCodeCredentials instance,
) => <String, dynamic>{
  'token_type': instance.tokenType,
  'access_token': instance.accessToken,
  'refresh_token': instance.refreshToken,
  'expires_at': const _DateTimeConverter().toJson(instance.expiresAt),
};
