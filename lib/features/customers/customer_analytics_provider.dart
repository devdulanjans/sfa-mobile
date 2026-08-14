import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/api_client.dart';

final customerAnalyticsProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, customerId) async {
  final resp = await ref.read(dioProvider).get('/customers/$customerId/analytics');
  return resp.data as Map<String, dynamic>;
});

final customerOrdersProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, customerId) async {
  final resp = await ref.read(dioProvider).get(
    '/customers/$customerId/orders',
    queryParameters: {'page': 0, 'size': 30, 'sort': 'orderDate,desc'},
  );
  return List<Map<String, dynamic>>.from(resp.data['content'] as List);
});

final customerReturnsProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, customerId) async {
  final resp = await ref.read(dioProvider).get(
    '/customers/$customerId/returns',
    queryParameters: {'page': 0, 'size': 30, 'sort': 'createdAt,desc'},
  );
  return List<Map<String, dynamic>>.from(resp.data['content'] as List);
});

final customerDamagesProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, customerId) async {
  final resp = await ref.read(dioProvider).get(
    '/customers/$customerId/damages',
    queryParameters: {'page': 0, 'size': 30, 'sort': 'damageDate,desc'},
  );
  return List<Map<String, dynamic>>.from(resp.data['content'] as List);
});
