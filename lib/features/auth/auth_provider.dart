import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import '../../core/network/api_client.dart';
import '../../core/storage/local_db.dart';
import '../../core/storage/sync_service.dart';

class WrongAppException implements Exception {
  final String message;
  const WrongAppException(this.message);
  @override
  String toString() => message;
}

class DistributorInfo {
  final String id;
  final String code;
  final String name;

  const DistributorInfo({
    required this.id,
    required this.code,
    required this.name,
  });

  factory DistributorInfo.fromJson(Map<String, dynamic> json) => DistributorInfo(
        id:   json['id']   as String,
        code: json['code'] as String,
        name: json['name'] as String,
      );

  Map<String, dynamic> toJson() => {'id': id, 'code': code, 'name': name};
}

class AuthUser {
  final String username;
  final String email;
  final String fullName;
  final String role;
  final List<DistributorInfo> distributors;
  final String? activeDistributorId;

  const AuthUser({
    required this.username,
    required this.email,
    required this.fullName,
    required this.role,
    required this.distributors,
    this.activeDistributorId,
  });

  // Returns null when activeDistributorId is null (meaning "All Distributors").
  DistributorInfo? get activeDistributor {
    if (distributors.isEmpty || activeDistributorId == null) return null;
    return distributors.firstWhere(
      (d) => d.id == activeDistributorId,
      orElse: () => distributors.first,
    );
  }

  AuthUser copyWith({String? activeDistributorId}) => AuthUser(
        username:            username,
        email:               email,
        fullName:            fullName,
        role:                role,
        distributors:        distributors,
        activeDistributorId: activeDistributorId ?? this.activeDistributorId,
      );
}

final authStateProvider = FutureProvider<AuthUser?>((ref) async {
  const storage = FlutterSecureStorage();
  final token = await storage.read(key: 'access_token');
  if (token == null) return null;

  final username    = await storage.read(key: 'username')      ?? '';
  final email       = await storage.read(key: 'email')         ?? '';
  final fullName    = await storage.read(key: 'full_name')     ?? '';
  final role        = await storage.read(key: 'role')          ?? '';
  final distsJson   = await storage.read(key: 'distributors')  ?? '[]';
  final activeDistId = await storage.read(key: 'active_distributor_id');

  final dists = (jsonDecode(distsJson) as List)
      .map((e) => DistributorInfo.fromJson(e as Map<String, dynamic>))
      .toList();

  return AuthUser(
    username:            username,
    email:               email,
    fullName:            fullName,
    role:                role,
    distributors:        dists,
    activeDistributorId: activeDistId,
  );
});

bool _isTokenExpired(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return true;
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    ) as Map<String, dynamic>;
    final exp = payload['exp'] as int;
    // Treat as expired if less than 30 seconds remain
    return DateTime.fromMillisecondsSinceEpoch(exp * 1000)
        .isBefore(DateTime.now().add(const Duration(seconds: 30)));
  } catch (_) {
    return true;
  }
}

class AuthNotifier extends AsyncNotifier<AuthUser?> {
  static const _storage = FlutterSecureStorage();

  @override
  Future<AuthUser?> build() async {
    // When the Dio interceptor clears storage after a failed refresh it
    // increments sessionExpiredProvider. Listening here forces a rebuild
    // that returns null, which GoRouter picks up and redirects to /login.
    ref.listen(sessionExpiredProvider, (_, __) async {
      await _storage.deleteAll();
      state = const AsyncData(null);
      ref.read(sessionExpiredProvider.notifier).update((s) => 0);
    });

    final accessToken  = await _storage.read(key: 'access_token');
    final refreshToken = await _storage.read(key: 'refresh_token');

    // No prior session at all
    if (accessToken == null && refreshToken == null) return null;

    // Proactively refresh when the access token is expired or missing
    if (accessToken == null || _isTokenExpired(accessToken)) {
      if (refreshToken == null) return null;
      try {
        final response = await Dio().post(
          '${ref.read(apiBaseUrlProvider)}/auth/refresh',
          data: {'refreshToken': refreshToken},
        );
        final data = response.data as Map<String, dynamic>;
        await _storage.write(key: 'access_token',  value: data['accessToken']  as String);
        await _storage.write(key: 'refresh_token', value: data['refreshToken'] as String);
        await _storage.write(key: 'username',  value: data['username']  as String? ?? '');
        await _storage.write(key: 'email',     value: data['email']     as String? ?? '');
        await _storage.write(key: 'full_name', value: data['fullName']  as String? ?? '');
        await _storage.write(key: 'role',      value: data['role']      as String? ?? '');
      } catch (_) {
        // Refresh token expired or revoked — force re-login; GoRouter redirects to /login
        await _storage.deleteAll();
        return null;
      }
    }

    final token = await _storage.read(key: 'access_token');
    if (token == null) return null;

    final username     = await _storage.read(key: 'username')           ?? '';
    final email        = await _storage.read(key: 'email')              ?? '';
    final fullName     = await _storage.read(key: 'full_name')          ?? '';
    final role         = await _storage.read(key: 'role')               ?? '';
    final distsJson    = await _storage.read(key: 'distributors')       ?? '[]';
    final activeDistId = await _storage.read(key: 'active_distributor_id');

    final dists = (jsonDecode(distsJson) as List)
        .map((e) => DistributorInfo.fromJson(e as Map<String, dynamic>))
        .toList();

    return AuthUser(
      username:            username,
      email:               email,
      fullName:            fullName,
      role:                role,
      distributors:        dists,
      activeDistributorId: activeDistId,
    );
  }

  Future<void> login(String username, String password) async {
    final dio  = ref.read(dioProvider);
    final resp = await dio.post('/auth/login', data: {
      'username': username,
      'password': password,
    });
    final data = resp.data as Map<String, dynamic>;

    // Customer accounts have a customerId — they must use the Customer Portal.
    final customerId = data['customerId'] as String?;
    if (customerId != null && customerId.isNotEmpty) {
      throw const WrongAppException(
        'This app is for sales personnel only. '
        'Please use the Customer Portal to access your account.',
      );
    }

    final rawDists = data['distributors'] as List? ?? [];
    final dists    = rawDists.map((e) => DistributorInfo.fromJson(e as Map<String, dynamic>)).toList();
    final defaultDistId = dists.isNotEmpty ? dists.first.id : null;

    await _storage.write(key: 'access_token',           value: data['accessToken']  as String);
    await _storage.write(key: 'refresh_token',          value: data['refreshToken'] as String);
    await _storage.write(key: 'username',               value: data['username']     as String);
    await _storage.write(key: 'email',                  value: data['email']        as String);
    await _storage.write(key: 'full_name',              value: data['fullName']     as String? ?? '');
    await _storage.write(key: 'role',                   value: data['role']         as String);
    await _storage.write(key: 'distributors',           value: jsonEncode(rawDists));
    if (defaultDistId != null) {
      await _storage.write(key: 'active_distributor_id', value: defaultDistId);
    }

    state = AsyncData(AuthUser(
      username:            data['username']  as String,
      email:               data['email']     as String,
      fullName:            data['fullName']  as String? ?? '',
      role:                data['role']      as String,
      distributors:        dists,
      activeDistributorId: defaultDistId,
    ));

    // Clear stale customer cache so the next sync fetches only this user's accessible customers
    await LocalDb.clearCustomerCache();
    ref.read(syncServiceProvider).sync();
  }

  Future<void> switchDistributor(String distributorId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final valid = current.distributors.any((d) => d.id == distributorId);
    if (!valid) return;
    await _storage.write(key: 'active_distributor_id', value: distributorId);
    state = AsyncData(current.copyWith(activeDistributorId: distributorId));
  }

  // Selects "All Distributors" — clears the active distributor context.
  Future<void> clearDistributor() async {
    final current = state.valueOrNull;
    if (current == null) return;
    await _storage.delete(key: 'active_distributor_id');
    state = AsyncData(AuthUser(
      username:            current.username,
      email:               current.email,
      fullName:            current.fullName,
      role:                current.role,
      distributors:        current.distributors,
      activeDistributorId: null,
    ));
  }

  Future<void> logout() async {
    try {
      final dio = ref.read(dioProvider);
      await dio.post('/auth/logout');
    } catch (_) {}
    await Future.wait([
      _storage.deleteAll(),
      LocalDb.clearAll(),
    ]);
    state = const AsyncData(null);
  }
}

final authNotifierProvider = AsyncNotifierProvider<AuthNotifier, AuthUser?>(AuthNotifier.new);
