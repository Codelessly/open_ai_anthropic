import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:open_ai_anthropic/src/model/claude_code_credentials.dart';
import 'package:open_ai_anthropic/src/utils/claude_code_token_store.dart';

ShortLivedClaudeCodeCredentials _expiredCreds() =>
    ShortLivedClaudeCodeCredentials(
      accessToken: 'old-access-token',
      refreshToken: 'test-refresh-token',
      expiresAt: DateTime.timestamp().subtract(Duration(hours: 1)),
    );

ShortLivedClaudeCodeCredentials _validCreds() =>
    ShortLivedClaudeCodeCredentials(
      accessToken: 'valid-access-token',
      refreshToken: 'test-refresh-token',
      expiresAt: DateTime.timestamp().add(Duration(hours: 1)),
    );

LongLivedClaudeCodeCredentials _expiredLongLivedCreds() =>
    LongLivedClaudeCodeCredentials(
      accessToken: 'long-lived-token',
      expiresAt: DateTime.timestamp().subtract(Duration(hours: 1)),
    );

MockClient _mockRefreshClient({
  String newAccessToken = 'new-access-token',
  String newRefreshToken = 'new-refresh-token',
  int expiresIn = 3600,
  int statusCode = 200,
}) {
  return MockClient((request) async {
    if (statusCode != 200) {
      return http.Response('{"error":"invalid_grant"}', statusCode);
    }
    return http.Response(
      jsonEncode({
        'access_token': newAccessToken,
        'refresh_token': newRefreshToken,
        'token_type': 'Bearer',
        'expires_in': expiresIn,
      }),
      200,
    );
  });
}

void main() {
  group('ClaudeCodeTokenStore', () {
    group('getAccessToken', () {
      test('returns current token when not expired', () async {
        final store = ClaudeCodeTokenStore(
          _validCreds(),
          client: _mockRefreshClient(),
        );

        final token = await store.getAccessToken();
        expect(token, 'valid-access-token');
      });

      test('refreshes and returns new token when expired', () async {
        final store = ClaudeCodeTokenStore(
          _expiredCreds(),
          client: _mockRefreshClient(newAccessToken: 'refreshed-token'),
        );

        final token = await store.getAccessToken();
        expect(token, 'refreshed-token');
      });

      test('throws for expired long-lived credentials', () async {
        final store = ClaudeCodeTokenStore(
          _expiredLongLivedCreds(),
          client: _mockRefreshClient(),
        );

        expect(
          () => store.getAccessToken(),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('refresh', () {
      test('sends correct POST request', () async {
        late http.Request capturedRequest;
        final client = MockClient((request) async {
          capturedRequest = request;
          return http.Response(
            jsonEncode({
              'access_token': 'new-token',
              'refresh_token': 'new-refresh',
              'token_type': 'Bearer',
              'expires_in': 3600,
            }),
            200,
          );
        });

        final store = ClaudeCodeTokenStore(_expiredCreds(), client: client);
        await store.refresh();

        expect(capturedRequest.method, 'POST');
        expect(
          capturedRequest.url.toString(),
          'https://platform.claude.com/v1/oauth/token',
        );
        expect(capturedRequest.headers['Content-Type'], 'application/json');
        expect(capturedRequest.headers['Accept'], 'application/json');

        final body = jsonDecode(capturedRequest.body) as Map<String, dynamic>;
        expect(body['grant_type'], 'refresh_token');
        expect(body['client_id'], '9d1c250a-e61b-44d9-88ed-5944d1962f5e');
        expect(body['refresh_token'], 'test-refresh-token');
      });

      test('updates stored credentials after refresh', () async {
        final store = ClaudeCodeTokenStore(
          _expiredCreds(),
          client: _mockRefreshClient(
            newAccessToken: 'updated-token',
            newRefreshToken: 'updated-refresh',
          ),
        );

        await store.refresh();

        final creds = store.credentials as ShortLivedClaudeCodeCredentials;
        expect(creds.accessToken, 'updated-token');
        expect(creds.refreshToken, 'updated-refresh');
      });

      test('invokes onTokenRefreshedCallback with new credentials', () async {
        ClaudeCodeCredentials? callbackCreds;
        final store = ClaudeCodeTokenStore(
          _expiredCreds(),
          client: _mockRefreshClient(newAccessToken: 'cb-token'),
          onTokenRefreshedCallback: (creds) async {
            callbackCreds = creds;
          },
        );

        await store.refresh();

        expect(callbackCreds, isNotNull);
        expect(callbackCreds!.accessToken, 'cb-token');
      });

      test('throws on non-200 response', () async {
        final store = ClaudeCodeTokenStore(
          _expiredCreds(),
          client: _mockRefreshClient(statusCode: 401),
        );

        expect(() => store.refresh(), throwsA(isA<Exception>()));
      });

      test('throws when called on long-lived credentials', () async {
        final store = ClaudeCodeTokenStore(
          LongLivedClaudeCodeCredentials(
            accessToken: 'long-lived',
            expiresAt: DateTime.timestamp().add(Duration(hours: 1)),
          ),
          client: _mockRefreshClient(),
        );

        expect(
          () => store.refresh(),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot refresh long-lived credentials'),
          )),
        );
      });
    });
  });
}
