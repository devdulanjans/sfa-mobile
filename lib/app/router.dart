import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../shared/widgets/app_bottom_nav.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/auth_provider.dart';
import '../features/auth/distributor_selector_screen.dart';
import '../features/mileage/mileage_provider.dart';
import '../features/mileage/start_mileage_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/customers/customers_screen.dart';
import '../features/customers/customer_detail_screen.dart';
import '../features/orders/order_list_screen.dart';
import '../features/orders/order_creation_screen.dart';
import '../features/orders/order_detail_screen.dart';
import '../features/orders/order_review_screen.dart';
import '../features/invoices/invoice_screen.dart';
import '../features/returns/return_form_screen.dart';
import '../features/damages/damage_form_screen.dart';
import '../features/sync/sync_screen.dart';
import '../features/sync/sync_provider.dart';
import '../features/sync/error_log_screen.dart';

class _RouterNotifier extends ChangeNotifier {
  _RouterNotifier(Ref ref) {
    ref.listen<AsyncValue<AuthUser?>>(authNotifierProvider, (_, __) {
      notifyListeners();
    });
    ref.listen<AsyncValue<MileageStatus>>(mileageNotifierProvider, (_, __) {
      notifyListeners();
    });
  }
}

final _routerNotifierProvider = Provider((ref) => _RouterNotifier(ref));

final routerProvider = Provider<GoRouter>((ref) {
  final notifier = ref.watch(_routerNotifierProvider);

  return GoRouter(
    initialLocation: '/dashboard',
    refreshListenable: notifier,
    redirect: (context, state) {
      final auth = ref.read(authNotifierProvider);
      if (auth.isLoading) return null;
      final user     = auth.valueOrNull;
      final loggedIn = user != null;
      final loc      = state.matchedLocation;

      if (!loggedIn && loc != '/login') return '/login';
      if (loggedIn  && loc == '/login') {
        if (user.distributors.length > 1 && user.activeDistributorId == null) {
          return '/select-distributor';
        }
        return '/dashboard';
      }

      // Mandatory start-mileage gate (SALES_REP only) — required at the start of
      // every session (a rep who logged out after recording end mileage must
      // enter start mileage again on their next login, even the same day).
      // Skipped while still resolving the distributor picker so a
      // multi-distributor user isn't asked for both at once — once they pick a
      // distributor and navigate away, this re-evaluates for the new location.
      if (loggedIn && loc != '/select-distributor' && loc != '/start-mileage') {
        final mileage = ref.read(mileageNotifierProvider);
        if (!mileage.isLoading && (mileage.valueOrNull?.needsStart ?? false)) {
          return '/start-mileage';
        }
      }

      return null;
    },
    routes: [
      // ── Auth (no shell) ───────────────────────────────────────────────────
      GoRoute(path: '/login', builder: (c, s) => const LoginScreen()),
      GoRoute(
        path: '/select-distributor',
        builder: (c, s) => DistributorSelectorScreen(
          isSwitch: s.uri.queryParameters['switch'] == 'true',
        ),
      ),
      GoRoute(
        path: '/start-mileage',
        builder: (c, s) => const StartMileageScreen(),
      ),

      // ── Main shell (bottom nav shown on all app screens) ─────────────────
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (c, s) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/customers',
            builder: (c, s) => const CustomersScreen(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (c, s) =>
                    CustomerDetailScreen(id: s.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/orders',
            builder: (c, s) => const OrderListScreen(),
            routes: [
              GoRoute(path: 'new',    builder: (c, s) => const OrderCreationScreen()),
              GoRoute(path: 'review', builder: (c, s) => const OrderReviewScreen()),
              GoRoute(
                path: ':id',
                builder: (c, s) =>
                    OrderDetailScreen(id: s.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/sync',
            builder: (c, s) => const SyncScreen(),
          ),
          GoRoute(
            path: '/invoices/:id',
            builder: (c, s) => InvoiceScreen(id: s.pathParameters['id']!),
          ),
          GoRoute(path: '/logs',        builder: (c, s) => const ErrorLogScreen()),
          GoRoute(
            path: '/returns/new',
            builder: (c, s) {
              final extra = s.extra as Map<String, String>?;
              return ReturnFormScreen(
                preselectedCustomerId:   extra?['id'],
                preselectedCustomerName: extra?['name'],
              );
            },
          ),
          GoRoute(
            path: '/damages/new',
            builder: (c, s) {
              final extra = s.extra as Map<String, String>?;
              return DamageFormScreen(
                preselectedCustomerId:   extra?['id'],
                preselectedCustomerName: extra?['name'],
              );
            },
          ),
        ],
      ),
    ],
    errorBuilder: (c, s) => Scaffold(
      body: Center(child: Text('Page not found: ${s.uri}')),
    ),
  );
});

// ─── Shell widget ─────────────────────────────────────────────────────────────

class AppShell extends ConsumerWidget {
  final String location;
  final Widget child;
  const AppShell({super.key, required this.location, required this.child});

  int get _index {
    if (location.startsWith('/customers')) return 1;
    if (location.startsWith('/orders'))    return 2;
    if (location.startsWith('/sync'))      return 3;
    return 0;
  }

  void _onTap(BuildContext context, int i) {
    switch (i) {
      case 1: context.go('/customers'); break;
      case 2: context.go('/orders');    break;
      case 3: context.go('/sync');      break;
      default: context.go('/dashboard');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState    = ref.watch(syncNotifierProvider);
    final pendingCount = syncState.pendingOrderCount;

    return Scaffold(
      body: child,
      bottomNavigationBar: AppBottomNav(
        selectedIndex: _index,
        onTap: (i) => _onTap(context, i),
        items: [
          const AppNavItem(
            icon: Icons.home_outlined,
            selectedIcon: Icons.home_rounded,
          ),
          const AppNavItem(
            icon: Icons.people_outline,
            selectedIcon: Icons.people_rounded,
          ),
          const AppNavItem(
            icon: Icons.receipt_long_outlined,
            selectedIcon: Icons.receipt_long_rounded,
          ),
          AppNavItem(
            icon: Icons.cloud_sync_outlined,
            selectedIcon: Icons.cloud_sync_rounded,
            badgeCount: pendingCount,
          ),
        ],
      ),
    );
  }
}
