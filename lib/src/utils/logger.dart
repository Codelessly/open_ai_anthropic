import 'dart:developer' as developer;

/// Logger for the Anthropic OpenAI client.
///
/// Logs warnings for unsupported parameters and other non-critical issues.
class AnthropicOpenAILogger {
  static const _name = 'AnthropicOpenAIClient';

  /// Log a warning message.
  static void warn(String message) {
    developer.log(message, name: _name, level: 900);
  }

  /// Log a warning for an unsupported parameter.
  static void logUnsupportedParam(String paramName, [dynamic value]) {
    if (value != null) {
      warn('Parameter "$paramName" is not supported by Anthropic and will be ignored');
    }
  }
}
