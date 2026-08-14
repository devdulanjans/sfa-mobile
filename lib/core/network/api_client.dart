import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../storage/local_db.dart';

const String _defaultApiBase =
    String.fromEnvironment('API_URL', defaultValue: 'http://168.144.28.98:8080/api');
const _apiBaseSettingsKey = 'api_base_url';

final _secureStorage = const FlutterSecureStorage();

/// The backend base URL, editable at runtime (tap the login screen's logo
/// 10 times to reveal the server address dialog) so a physical device can
/// point at a different backend without a rebuild. Falls back to
/// [_defaultApiBase] until the user sets one explicitly.
final apiBaseUrlProvider = StateProvider<String>(
  (ref) => LocalDb.settingsBox.get(_apiBaseSettingsKey) as String? ?? _defaultApiBase,
);

Future<void> setApiBaseUrl(WidgetRef ref, String url) async {
  final trimmed = url.trim();
  await LocalDb.settingsBox.put(_apiBaseSettingsKey, trimmed);
  ref.read(apiBaseUrlProvider.notifier).state = trimmed;
}

// Incremented whenever a refresh fails and the session must be cleared.
// auth_provider.dart listens to this to reset auth state and trigger login redirect.
final sessionExpiredProvider = StateProvider<int>((ref) => 0);

final dioProvider = Provider<Dio>((ref) {
  final apiBase = ref.watch(apiBaseUrlProvider);

  final dio = Dio(BaseOptions(
    baseUrl: apiBase,
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    headers: {'Content-Type': 'application/json'},
  ));

  // Auth interceptor
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      final token = await _secureStorage.read(key: 'access_token');
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      handler.next(options);
    },
    onError: (error, handler) async {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        try {
          final refreshToken = await _secureStorage.read(key: 'refresh_token');
          if (refreshToken == null) throw Exception('No refresh token');
          final response = await Dio().post('$apiBase/auth/refresh',
              data: {'refreshToken': refreshToken});
          await _secureStorage.write(key: 'access_token',  value: response.data['accessToken']);
          await _secureStorage.write(key: 'refresh_token', value: response.data['refreshToken']);
          error.requestOptions.headers['Authorization'] = 'Bearer ${response.data['accessToken']}';
          final retryResponse = await dio.fetch(error.requestOptions);
          handler.resolve(retryResponse);
        } catch (_) {
          await _secureStorage.deleteAll();
          ref.read(sessionExpiredProvider.notifier).update((s) => s + 1);
          handler.next(error);
        }
      } else {
        handler.next(error);
      }
    },
  ));

  // Logging in debug mode
  assert(() {
    dio.interceptors.add(LogInterceptor(requestBody: true, responseBody: true));
    return true;
  }());

  return dio;
});
