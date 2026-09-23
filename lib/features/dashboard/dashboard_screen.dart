import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../app/colors.dart';
import '../../app/radii.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/sync_service.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/stat_tile.dart';
import '../../utils/formatters.dart';
import '../auth/auth_provider.dart';
import '../mileage/mileage_provider.dart';
import '../targets/target_provider.dart';

// ─── Date-range preset ────────────────────────────────────────────────────────

enum _Range { today, week, month, custom }

extension _RangeX on _Range {
  String get label => switch (this) {
    _Range.today  => 'Today',
    _Range.week   => '7 Days',
    _Range.month  => '30 Days',
    _Range.custom => 'Custom',
  };
}

// ─── Screen ──────────────────────────────────────────────────────────────────

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});
  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  // Shared state for both roles
  _Range _range      = _Range.month;
  DateTime _from     = DateTime.now().subtract(const Duration(days: 29));
  DateTime _to       = DateTime.now();
  Map<String, dynamic>? _data;
  bool  _loading     = false;
  String? _error;

  // Manager-only
  String?  _selectedRepId;
  String?  _selectedRepName;
  List<Map<String, dynamic>> _salesReps = [];
  bool    _repsLoaded = false;

  // Distributor-change detection
  String? _lastDistributorId;
  // Channel-change detection — same pattern as distributor above.
  String? _lastTenantId;
  bool    _initDone = false;

  final _apiFmt     = DateFormat('yyyy-MM-dd');
  final _displayFmt = DateFormat('dd MMM yyyy');

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _applyRange(_Range.month);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(syncServiceProvider).sync();
    });
  }

  void _applyRange(_Range r, {DateTime? customFrom, DateTime? customTo}) {
    final now = DateTime.now();
    setState(() {
      _range = r;
      switch (r) {
        case _Range.today:
          _from = DateTime(now.year, now.month, now.day);
          _to   = now;
        case _Range.week:
          _from = now.subtract(const Duration(days: 6));
          _to   = now;
        case _Range.month:
          _from = now.subtract(const Duration(days: 29));
          _to   = now;
        case _Range.custom:
          if (customFrom != null) _from = customFrom;
          if (customTo   != null) _to   = customTo;
      }
    });
    _loadData();
  }

  Future<void> _pickCustomRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _from, end: _to),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme.copyWith(
            primary: Theme.of(ctx).colorScheme.primary,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      _applyRange(_Range.custom, customFrom: picked.start, customTo: picked.end);
    }
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final dio  = ref.read(dioProvider);
      final user = ref.read(authNotifierProvider).valueOrNull;
      final distributorId = user?.activeDistributorId;
      final params = <String, dynamic>{
        'from': _apiFmt.format(_from),
        'to':   _apiFmt.format(_to),
        if (_selectedRepId  != null) 'salesRepId':    _selectedRepId,
        if (distributorId   != null) 'distributorId': distributorId,
      };
      final resp = await dio.get('/dashboard', queryParameters: params);
      if (mounted) setState(() => _data = resp.data as Map<String, dynamic>);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadSalesReps() async {
    try {
      final resp = await ref.read(dioProvider).get('/dashboard/sales-reps');
      if (mounted) {
        setState(() {
          _salesReps  = List<Map<String, dynamic>>.from(resp.data as List);
          _repsLoaded = true;
        });
      }
    } catch (_) {}
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final user       = ref.watch(authNotifierProvider).valueOrNull;
    final isSalesRep = user?.role == 'SALES_REP';
    final mileage    = ref.watch(mileageNotifierProvider).valueOrNull ?? const MileageStatus(applicable: false);
    final targets    = ref.watch(salesTargetNotifierProvider).valueOrNull ?? const [];

    // Initial load
    if (user != null && !_initDone) {
      _initDone            = true;
      _lastDistributorId   = user.activeDistributorId;
      _lastTenantId        = user.activeTenantId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadData();
        if (!isSalesRep) _loadSalesReps();
      });
    }

    // Reload on distributor switch
    if (user != null && _initDone &&
        user.activeDistributorId != _lastDistributorId) {
      _lastDistributorId = user.activeDistributorId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
    }

    // Reload on channel switch — same gap as the distributor one above, just for
    // AuthUser.activeTenantId (set by AuthNotifier.switchChannel).
    if (user != null && _initDone &&
        user.activeTenantId != _lastTenantId) {
      _lastTenantId = user.activeTenantId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
    }

    final showDistributorRow = (user?.distributors.length ?? 0) > 0;

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Hello, ${user?.fullName.split(' ').first ?? 'there'} 👋',
              style: const TextStyle(fontSize: 16)),
          if (showDistributorRow)
            GestureDetector(
              onTap: user!.distributors.length > 1
                  ? () => showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) => _DistributorSheet(user: user),
                      )
                  : null,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.storefront_outlined, size: 11, color: Colors.grey),
                const SizedBox(width: 3),
                Text(
                  user!.activeDistributorId != null
                      ? (user.activeDistributor?.name ?? '')
                      : 'All Distributors',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                if (user.distributors.length > 1)
                  const Icon(Icons.arrow_drop_down, size: 14, color: Colors.grey),
              ]),
            ),
        ]),
        automaticallyImplyLeading: false,
        actions: [
          if ((user?.tenants.length ?? 0) > 1)
            IconButton(
              icon: const Icon(Icons.hub_outlined),
              tooltip: 'Switch Channel',
              onPressed: () => context.push('/select-channel?switch=true'),
            ),
          if ((user?.distributors.length ?? 0) > 1)
            IconButton(
              icon: const Icon(Icons.swap_horiz_outlined),
              tooltip: 'Switch Distributor',
              onPressed: () => context.push('/select-distributor?switch=true'),
            ),
          IconButton(
            icon: const Icon(Icons.logout_outlined),
            onPressed: () => handleLogoutTap(context, ref),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Today's sales target ────────────────────────────────────────
            if (targets.isNotEmpty) ...[
              _TodaysTargetCard(targets: targets),
              const SizedBox(height: 12),
            ],

            // ── Open mileage session indicator ──────────────────────────────
            if (mileage.needsEnd) ...[
              _MileageSessionCard(startMileage: mileage.startMileage!),
              const SizedBox(height: 12),
            ],

            // ── Manager rep picker ─────────────────────────────────────────
            if (!isSalesRep && _repsLoaded) ...[
              _RepPicker(
                reps: _salesReps,
                selectedId: _selectedRepId,
                selectedName: _selectedRepName,
                onChanged: (id, name) {
                  setState(() { _selectedRepId = id; _selectedRepName = name; });
                  _loadData();
                },
              ),
              const SizedBox(height: 12),
            ],

            // ── Date range chips ───────────────────────────────────────────
            _DateRangeBar(
              selected: _range,
              from: _from,
              to: _to,
              displayFmt: _displayFmt,
              onSelect: (r) {
                if (r == _Range.custom) {
                  _pickCustomRange();
                } else {
                  _applyRange(r);
                }
              },
            ),
            const SizedBox(height: 16),

            // ── Quick Actions ──────────────────────────────────────────────
            Row(children: [
              Expanded(child: _QuickActionCard(
                icon: Icons.assignment_return_outlined,
                label: 'New Return',
                tone: AppTone.orange,
                onTap: () => context.push('/returns/new'),
              )),
              const SizedBox(width: 12),
              Expanded(child: _QuickActionCard(
                icon: Icons.report_problem_outlined,
                label: 'Record Damage',
                tone: AppTone.pink,
                onTap: () => context.push('/damages/new'),
              )),
            ]),
            const SizedBox(height: 16),

            // ── Content ────────────────────────────────────────────────────
            if (_loading && _data == null)
              const Center(child: Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: CircularProgressIndicator(),
              ))
            else if (_error != null && _data == null)
              Center(child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Column(children: [
                  const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
                  const SizedBox(height: 12),
                  Text('Could not load data', style: TextStyle(color: Colors.grey.shade600)),
                  TextButton(onPressed: _loadData, child: const Text('Retry')),
                ]),
              ))
            else if (_data != null)
              _DashboardBody(data: _data!, loading: _loading),
          ],
        ),
      ),
    );
  }
}

// ─── Today's sales target ─────────────────────────────────────────────────────

class _TodaysTargetCard extends StatelessWidget {
  final List<TargetStatus> targets;
  const _TodaysTargetCard({required this.targets});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tone: AppTone.mint,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.track_changes_rounded, color: AppColors.mintFg, size: 18),
          SizedBox(width: 8),
          Text("Today's Target",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        ...targets.map((t) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Expanded(
                  child: Text(t.productName,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis),
                ),
                Text(
                  t.todayTarget != null
                      ? '${t.achievedToday?.toStringAsFixed(0) ?? 0} / ${t.todayTarget!.toStringAsFixed(0)}'
                      : '—',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.mintFg),
                ),
              ]),
            )),
      ]),
    );
  }
}

// ─── Open mileage session indicator ──────────────────────────────────────────

class _MileageSessionCard extends StatelessWidget {
  final double startMileage;
  const _MileageSessionCard({required this.startMileage});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tone: AppTone.violet,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        const Icon(Icons.speed_rounded, color: AppColors.violetFg, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Start Mileage',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              Text('${startMileage.toStringAsFixed(1)} km',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ]),
    );
  }
}

// ─── Dashboard body (all charts + lists) ─────────────────────────────────────

class _DashboardBody extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool loading;
  const _DashboardBody({required this.data, required this.loading});

  @override
  Widget build(BuildContext context) {
    final daily         = (data['dailyRevenue']   as List?)?.cast<Map<String, dynamic>>() ?? [];
    final statusMap     = (data['statusBreakdown'] as Map?)?.cast<String, dynamic>()      ?? {};
    final topCustomers  = (data['topCustomers']   as List?)?.cast<Map<String, dynamic>>() ?? [];
    final recentOrders  = (data['recentOrders']   as List?)?.cast<Map<String, dynamic>>() ?? [];

    final todayRev   = _bd(data['todayRevenue']);
    final monthRev   = _bd(data['monthRevenue']);
    final totalRev   = _bd(data['totalRevenue']);
    final todayOrds  = (data['todayOrders'] as num?)?.toInt() ?? 0;
    final avgOrder   = (data['todayOrders'] as num? ?? 0) > 0
        ? totalRev / (data['todayOrders'] as num).toDouble()
        : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── KPI tiles ────────────────────────────────────────────────────
        Row(children: [
          Expanded(child: StatTile(
            label: 'Today Revenue',
            value: 'LKR ${formatAmount(todayRev)}',
            icon:  Icons.today_rounded,
            tone:  AppTone.violet,
          )),
          const SizedBox(width: 10),
          Expanded(child: StatTile(
            label: 'Today Orders',
            value: '$todayOrds',
            icon:  Icons.shopping_bag_outlined,
            tone:  AppTone.orange,
          )),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: StatTile(
            label: 'Period Revenue',
            value: 'LKR ${formatAmount(totalRev)}',
            icon:  Icons.payments_outlined,
            tone:  AppTone.mint,
          )),
          const SizedBox(width: 10),
          Expanded(child: StatTile(
            label: 'Month Revenue',
            value: 'LKR ${formatAmount(monthRev)}',
            icon:  Icons.calendar_month_outlined,
            tone:  AppTone.sky,
          )),
        ]),
        const SizedBox(height: 24),

        // ── Revenue trend chart ───────────────────────────────────────────
        const SectionHeader(title: 'Revenue Trend', icon: Icons.show_chart_rounded,
            tone: AppTone.violet),
        const SizedBox(height: 10),
        _RevenueTrendCard(daily: daily),
        const SizedBox(height: 24),

        // ── Order status pie chart ────────────────────────────────────────
        const SectionHeader(title: 'Order Status', icon: Icons.donut_large_rounded,
            tone: AppTone.orange),
        const SizedBox(height: 10),
        _StatusPieCard(statusMap: statusMap),
        const SizedBox(height: 24),

        // ── Top customers ─────────────────────────────────────────────────
        if (topCustomers.isNotEmpty) ...[
          const SectionHeader(title: 'Top Customers', icon: Icons.emoji_events_outlined,
              tone: AppTone.mint),
          const SizedBox(height: 10),
          _TopCustomersCard(customers: topCustomers),
          const SizedBox(height: 24),
        ],

        // ── Recent orders ─────────────────────────────────────────────────
        if (recentOrders.isNotEmpty) ...[
          const SectionHeader(title: 'Recent Orders', icon: Icons.receipt_long_outlined,
              tone: AppTone.sky),
          const SizedBox(height: 10),
          _RecentOrdersCard(orders: recentOrders),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  static double _bd(dynamic v) {
    if (v == null) return 0.0;
    if (v is num)    return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

}

// ─── Revenue trend line chart ─────────────────────────────────────────────────

class _RevenueTrendCard extends StatelessWidget {
  final List<Map<String, dynamic>> daily;
  const _RevenueTrendCard({required this.daily});

  @override
  Widget build(BuildContext context) {
    if (daily.isEmpty) {
      return const EmptyState(message: 'No revenue data for this period', icon: Icons.show_chart_rounded);
    }

    final spots = daily.asMap().entries.map((e) {
      final rev = (e.value['revenue'] as num?)?.toDouble() ?? 0.0;
      return FlSpot(e.key.toDouble(), rev);
    }).toList();

    final maxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final safeMax = maxY == 0 ? 1.0 : maxY * 1.15;
    // A single data point makes maxX == minX == 0 below — fl_chart scales
    // positions by (maxX - minX), so a zero-width domain draws nothing at
    // all. Widen it to a minimum span of 1 so the lone point still renders.
    final maxX = (daily.length - 1).toDouble();
    final safeMaxX = maxX <= 0 ? 1.0 : maxX;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: SizedBox(
        height: 180,
        child: LineChart(
          LineChartData(
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: safeMax / 4,
              getDrawingHorizontalLine: (v) => FlLine(
                  color: Colors.grey.shade200, strokeWidth: 1),
            ),
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 52,
                  getTitlesWidget: (v, _) => Text(
                    formatAmount(v),
                    style: const TextStyle(fontSize: 9, color: Colors.grey),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: daily.length <= 14,
                  reservedSize: 22,
                  interval: daily.length <= 7 ? 1 : (daily.length / 4).ceilToDouble(),
                  getTitlesWidget: (v, _) {
                    final i = v.toInt();
                    if (i < 0 || i >= daily.length) return const SizedBox.shrink();
                    final date = daily[i]['date'] as String? ?? '';
                    final parts = date.split('-');
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        parts.length == 3 ? '${parts[2]}/${parts[1]}' : date,
                        style: const TextStyle(fontSize: 9, color: Colors.grey),
                      ),
                    );
                  },
                ),
              ),
              topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            borderData: FlBorderData(show: false),
            minX: 0,
            maxX: safeMaxX,
            minY: 0,
            maxY: safeMax,
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: true,
                curveSmoothness: 0.35,
                color: const Color(0xFF667EEA),
                barWidth: 2.5,
                dotData: FlDotData(
                  show: daily.length <= 10,
                  getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
                    radius: 3,
                    color: const Color(0xFF667EEA),
                    strokeWidth: 1.5,
                    strokeColor: Colors.white,
                  ),
                ),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF667EEA).withValues(alpha: 0.3),
                      const Color(0xFF667EEA).withValues(alpha: 0.0),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ],
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (spots) => spots.map((s) {
                  final i = s.x.toInt();
                  final date = i < daily.length
                      ? (daily[i]['date'] as String? ?? '') : '';
                  return LineTooltipItem(
                    'LKR ${formatAmount(s.y)}\n',
                    const TextStyle(color: Colors.white,
                        fontWeight: FontWeight.bold, fontSize: 11),
                    children: [TextSpan(
                      text: date,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8), fontSize: 9),
                    )],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

}

// ─── Order status pie chart ───────────────────────────────────────────────────

class _StatusPieCard extends StatefulWidget {
  final Map<String, dynamic> statusMap;
  const _StatusPieCard({required this.statusMap});

  @override
  State<_StatusPieCard> createState() => _StatusPieCardState();
}

class _StatusPieCardState extends State<_StatusPieCard> {
  int _touched = -1;

  static const _colors = {
    'SUBMITTED': Color(0xFFF7971E),
    'APPROVED':  Color(0xFF11998E),
    'INVOICED':  Color(0xFF667EEA),
    'CANCELLED': Color(0xFFEB3349),
    'DRAFT':     Color(0xFFB0BEC5),
  };

  static const _labels = {
    'SUBMITTED': 'Submitted',
    'APPROVED':  'Approved',
    'INVOICED':  'Invoiced',
    'CANCELLED': 'Cancelled',
    'DRAFT':     'Draft',
  };

  @override
  Widget build(BuildContext context) {
    final entries = widget.statusMap.entries
        .where((e) => (e.value as num? ?? 0) > 0)
        .toList();

    if (entries.isEmpty) {
      return const EmptyState(message: 'No order data for this period', icon: Icons.donut_large_rounded);
    }

    final total = entries.fold<double>(
        0.0, (s, e) => s + (e.value as num).toDouble());

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Row(
        children: [
          // Pie chart
          SizedBox(
            width: 160,
            height: 160,
            child: PieChart(
              PieChartData(
                pieTouchData: PieTouchData(
                  touchCallback: (ev, resp) => setState(() =>
                      _touched = resp?.touchedSection?.touchedSectionIndex ?? -1),
                ),
                sections: entries.asMap().entries.map((e) {
                  final idx     = e.key;
                  final status  = e.value.key;
                  final count   = (e.value.value as num).toDouble();
                  final isTouched = idx == _touched;
                  final color   = _colors[status] ?? Colors.grey;
                  return PieChartSectionData(
                    value: count,
                    color: color,
                    radius: isTouched ? 68 : 56,
                    title: isTouched
                        ? '${((count / total) * 100).toStringAsFixed(0)}%'
                        : '',
                    titleStyle: const TextStyle(
                        color: Colors.white, fontSize: 11,
                        fontWeight: FontWeight.bold),
                    badgeWidget: null,
                  );
                }).toList(),
                sectionsSpace: 2,
                centerSpaceRadius: 30,
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Legend
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: entries.map((e) {
                final status = e.key;
                final count  = (e.value as num).toInt();
                final color  = _colors[status] ?? Colors.grey;
                final label  = _labels[status] ?? status;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(
                          color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(label,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w500)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('$count',
                          style: TextStyle(
                              fontSize: 11,
                              color: color,
                              fontWeight: FontWeight.w700)),
                    ),
                  ]),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Top customers card ───────────────────────────────────────────────────────

class _TopCustomersCard extends StatelessWidget {
  final List<Map<String, dynamic>> customers;
  const _TopCustomersCard({required this.customers});

  static const _barColors = [
    Color(0xFF667EEA), Color(0xFF11998E), Color(0xFFF7971E),
    Color(0xFFEB3349), Color(0xFF764BA2), Color(0xFF38EF7D),
    Color(0xFFFFD200), Color(0xFFF45C43), Color(0xFF4ECDC4), Color(0xFFFF6B6B),
  ];

  @override
  Widget build(BuildContext context) {
    final maxRev = customers.fold<double>(
        0.0, (s, c) => _rev(c['revenue']) > s ? _rev(c['revenue']) : s);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Column(
        children: customers.asMap().entries.map((e) {
          final idx   = e.key;
          final c     = e.value;
          final name  = c['name']       as String? ?? '—';
          final rev   = _rev(c['revenue']);
          final count = (c['orderCount'] as num?)?.toInt() ?? 0;
          final color = _barColors[idx % _barColors.length];
          final pct   = maxRev > 0 ? rev / maxRev : 0.0;

          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 22, height: 22,
                    decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Text('${idx + 1}',
                        style: TextStyle(fontSize: 9,
                            fontWeight: FontWeight.bold, color: color)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Text('LKR ${formatAmount(rev)}',
                      style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w700, color: color)),
                  const SizedBox(width: 6),
                  Text('($count ord${count == 1 ? '' : 's'})',
                      style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ]),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    backgroundColor: Colors.grey.shade100,
                    valueColor: AlwaysStoppedAnimation(color),
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  static double _rev(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }
}

// ─── Recent orders card ───────────────────────────────────────────────────────

class _RecentOrdersCard extends StatelessWidget {
  final List<Map<String, dynamic>> orders;
  const _RecentOrdersCard({required this.orders});

  static Color _statusColor(String status) => switch (status) {
    'APPROVED'  => const Color(0xFF11998E),
    'SUBMITTED' => const Color(0xFFF7971E),
    'INVOICED'  => const Color(0xFF667EEA),
    'CANCELLED' => const Color(0xFFEB3349),
    'DRAFT'     => Colors.grey,
    _           => Colors.grey,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Column(
        children: orders.asMap().entries.map((e) {
          final i      = e.key;
          final o      = e.value;
          final status = o['status'] as String? ?? '';
          final color  = _statusColor(status);
          final total  = (o['total'] as num?)?.toDouble() ?? 0.0;

          return Container(
            decoration: BoxDecoration(
              border: i < orders.length - 1
                  ? Border(bottom: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant))
                  : null,
            ),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              leading: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.receipt_outlined, color: color, size: 18),
              ),
              title: Text(o['orderNumber'] as String? ?? '—',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
              subtitle: Text(
                '${o['customerName'] ?? '—'}  ·  ${o['date'] ?? ''}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'LKR ${formatAmount(total)}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: color),
                  ),
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4)),
                    child: Text(status,
                        style: TextStyle(
                            fontSize: 9,
                            color: color,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── Date range bar ───────────────────────────────────────────────────────────

class _DateRangeBar extends StatelessWidget {
  final _Range selected;
  final DateTime from, to;
  final DateFormat displayFmt;
  final ValueChanged<_Range> onSelect;
  const _DateRangeBar({
    required this.selected, required this.from, required this.to,
    required this.displayFmt, required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: _Range.values.map((r) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilterChip(
            label: Text(r.label),
            selected: selected == r,
            onSelected: (_) => onSelect(r),
            showCheckmark: false,
            selectedColor: Theme.of(context).colorScheme.primary,
            labelStyle: TextStyle(
              color: selected == r ? Colors.white : null,
              fontSize: 12,
              fontWeight: selected == r ? FontWeight.w600 : FontWeight.normal,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          ),
        )).toList()),
        if (selected == _Range.custom) ...[
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.date_range_outlined, size: 14, color: Colors.grey),
            const SizedBox(width: 6),
            Text(
              '${displayFmt.format(from)}  –  ${displayFmt.format(to)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ]),
        ],
      ],
    );
  }
}

// ─── Rep picker (manager view) ────────────────────────────────────────────────

class _RepPicker extends StatelessWidget {
  final List<Map<String, dynamic>> reps;
  final String? selectedId, selectedName;
  final void Function(String? id, String? name) onChanged;
  const _RepPicker({
    required this.reps, required this.selectedId,
    required this.selectedName, required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Salesperson',
              style: TextStyle(
                  fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500)),
          DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              isExpanded: true,
              value: selectedId,
              hint: const Text('All Salespersons',
                  style: TextStyle(fontSize: 14)),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All Salespersons'),
                ),
                ...reps.map((rep) => DropdownMenuItem<String?>(
                  value: rep['id'] as String?,
                  child: Text(
                    rep['fullName'] as String? ??
                    rep['username'] as String? ?? '',
                  ),
                )),
              ],
              onChanged: (val) {
                final name = val == null
                    ? null
                    : reps.firstWhere((r) => r['id'] == val,
                            orElse: () => {})['fullName'] as String?;
                onChanged(val, name);
              },
            ),
          ),
        ]),
      ),
    );
  }
}

// ─── Distributor switcher sheet ───────────────────────────────────────────────

class _DistributorSheet extends ConsumerWidget {
  final AuthUser user;
  const _DistributorSheet({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2)),
          )),
          const SizedBox(height: 16),
          const Text('Switch Distributor',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: user.activeDistributorId == null
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade200,
              child: Icon(Icons.all_inclusive,
                  color: user.activeDistributorId == null
                      ? Colors.white : Colors.grey.shade600,
                  size: 18),
            ),
            title: const Text('All Distributors',
                style: TextStyle(fontWeight: FontWeight.w600)),
            trailing: user.activeDistributorId == null
                ? Icon(Icons.check_circle,
                    color: Theme.of(context).colorScheme.primary)
                : null,
            onTap: user.activeDistributorId == null ? null : () async {
              await ref.read(authNotifierProvider.notifier).clearDistributor();
              if (context.mounted) Navigator.pop(context);
            },
          ),
          const Divider(height: 8),
          ...user.distributors.map((dist) {
            final isActive = dist.id == user.activeDistributorId;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: isActive
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey.shade200,
                child: Icon(Icons.storefront_outlined,
                    color: isActive ? Colors.white : Colors.grey.shade600,
                    size: 18),
              ),
              title: Text(dist.name,
                  style: TextStyle(
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
              subtitle: Text(dist.code, style: const TextStyle(fontSize: 11)),
              trailing: isActive
                  ? Icon(Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary)
                  : null,
              onTap: isActive ? null : () async {
                await ref.read(authNotifierProvider.notifier)
                    .switchDistributor(dist.id);
                if (context.mounted) Navigator.pop(context);
              },
            );
          }),
        ],
      ),
    );
  }
}

// ─── Quick action card ────────────────────────────────────────────────────────

class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final AppTone tone;
  final VoidCallback onTap;
  const _QuickActionCard({
    required this.icon,
    required this.label,
    required this.tone,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = AppColors.foreground(tone);
    return AppCard(
      tone: tone,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      onTap: onTap,
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 20, color: fg),
        const SizedBox(width: 8),
        Flexible(child: Text(label,
            style: TextStyle(
                color: fg, fontWeight: FontWeight.w700, fontSize: 13),
            overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}
