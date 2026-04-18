// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'oauth_service.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TokenExchangeResponse _$TokenExchangeResponseFromJson(
  Map<String, dynamic> json,
) => TokenExchangeResponse(
  tokenType: json['token_type'] as String,
  accessToken: json['access_token'] as String,
  refreshToken: json['refresh_token'] as String,
  expiresIn: (json['expires_in'] as num).toInt(),
  scope: json['scope'] as String,
  organization: AnthropicOrganization.fromJson(
    json['organization'] as Map<String, dynamic>,
  ),
  account: AnthropicAccount.fromJson(json['account'] as Map<String, dynamic>),
  expiresAt: const DateTimeConverter().fromJson(
    (json['expires_at'] as num).toInt(),
  ),
);

Map<String, dynamic> _$TokenExchangeResponseToJson(
  TokenExchangeResponse instance,
) => <String, dynamic>{
  'token_type': instance.tokenType,
  'access_token': instance.accessToken,
  'refresh_token': instance.refreshToken,
  'expires_in': instance.expiresIn,
  'scope': instance.scope,
  'organization': instance.organization,
  'account': instance.account,
  'expires_at': const DateTimeConverter().toJson(instance.expiresAt),
};

AnthropicOrganization _$AnthropicOrganizationFromJson(
  Map<String, dynamic> json,
) => AnthropicOrganization(
  uuid: json['uuid'] as String,
  name: json['name'] as String,
);

Map<String, dynamic> _$AnthropicOrganizationToJson(
  AnthropicOrganization instance,
) => <String, dynamic>{'uuid': instance.uuid, 'name': instance.name};

AnthropicAccount _$AnthropicAccountFromJson(Map<String, dynamic> json) => AnthropicAccount(
  uuid: json['uuid'] as String,
  email: json['email_address'] as String,
);

Map<String, dynamic> _$AnthropicAccountToJson(AnthropicAccount instance) => <String, dynamic>{
  'uuid': instance.uuid,
  'email_address': instance.email,
};
