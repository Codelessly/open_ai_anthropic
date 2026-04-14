import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:open_ai_anthropic/oauth_service.dart';

Future<void> main() async {
  try {
    final service = ClaudeCodeOauthService();
    final redirectionPort = 10738;
    final redirectionUri = 'http://localhost:$redirectionPort/callback';
    final request = service.prepareOAuthRequest(redirectionUri: redirectionUri);

    final Completer<String> authCodeCompleter = Completer<String>();

    final server = await startRedirectionServer(authCodeCompleter, port: redirectionPort, endpoint: '/callback');

    print('\n🔐 Starting OAuth flow...\n');
    print('Please visit this URL to authorize:\n');
    print(request.authUrl);
    print('\n${'=' * 70}');
    print('After authorizing, if not auto redirected, copy the authorization code and paste it here:');
    print('=' * 70 + '\n');

    StreamSubscription? sub;
    sub = LineSplitter().bind(stdin.transform(utf8.decoder)).listen((data) {
      final code = data.trim();
      if (code.isNotEmpty) {
        authCodeCompleter.complete(code);
      }
    });

    final code = await authCodeCompleter.future;
    await Future.delayed(Duration(seconds: 1));
    await sub.cancel();
    await server.close(force: true);

    final credentials = await service.completeOAuthFlow(
      request: request,
      authCode: code,
      redirectionUri: redirectionUri,
    );

    // Write to a file!
    // File('claude_code_credentials.json').writeAsStringSync(JsonEncoder.withIndent('  ').convert(credentials.toJson()));

    final credentialsString = JsonEncoder.withIndent('  ').convert(credentials);
    File('claude_code_credentials.json').writeAsStringSync(credentialsString);

    print('✅ Token exchange successful!\n');
    print(credentialsString);
    print('✅ Done! Use these credentials to authenticate your requests to the ClaudeCodeClient.');
  } catch (e) {
    print('❌ Error: $e');
  }
}

Future<HttpServer> startRedirectionServer(
  Completer<String> authCodeCompleter, {
  required int port,
  required String endpoint,
}) async {
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);

  print('Redirection server running on http://localhost:$port');
  server.listen((request) async {
    final path = request.uri.path;

    if (path.isEmpty || path == '/') {
      // Just respond with a simple page for root requests
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(
          '''
          <html lang="en">
            <body style="font-family: Arial, sans-serif; text-align: center; padding: 50px;">
              <h1>OAuth Redirection Server</h1>
              <p>This server is used to capture the authorization code from the OAuth flow.</p>
            </body>
          </html>
          ''',
        );
      await request.response.close();
      return;
    }

    if (path == endpoint) {
      final queryParams = request.uri.queryParameters;
      final code = queryParams['code'];
      final state = queryParams['state'];

      if (code == null || state == null) {
        // return Response(400, body: 'Missing code or state');
        request.response
          ..statusCode = 400
          ..headers.contentType = ContentType.html
          ..write(
            '''
            <html lang="en">
              <body style="font-family: Arial, sans-serif; text-align: center; padding: 50px;">
                <h1>Authorization Failed</h1>
                <p>Missing code or state in the callback.</p>
              </body>
            </html>
            ''',
          );
        await request.response.close();
        return;
      }

      // In a real app, you'd verify the state matches what you originally sent
      print('Received auth code: $code');
      print('Received state: $state');

      // Respond to the browser immediately with message in HTML.
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(
          '''
          <html lang="en">
            <body style="font-family: Arial, sans-serif; text-align: center; padding: 50px;">
              <h1>Authorization Successful!</h1>
              <p>You can now close this window.</p>
            </body>
          </html>
          ''',
        );
      await request.response.close();
      authCodeCompleter.complete(code);
    }
  });

  return server;
}
