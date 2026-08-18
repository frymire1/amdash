import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/audit_log_entry.dart';
import '../services/admin_service.dart';
import '../widgets/admin_page.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Aug 15, 2026, 3:42 PM" — hand-rolled rather than pulling in `intl` for
/// a single date format in a whole app that doesn't otherwise use it.
String _formatTimestamp(DateTime timestamp) {
  final local = timestamp.toLocal();
  final hour24 = local.hour;
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = hour24 < 12 ? 'AM' : 'PM';
  return '${_months[local.month - 1]} ${local.day}, ${local.year}, $hour12:$minute $period';
}

/// Mirrors the shape of the other admin management screens, but read-only —
/// no create form, just a table. Backed by `listAuditLog`
/// (`functions/src/admin.ts`), which records every admin.ts mutation
/// (user/role/hospital/organization changes) plus patient-record events
/// logged from `functions/src/patients.ts` — EMS create/update/complete/
/// delete and physician/EMS PHI decrypt reads.
class AuditLogScreen extends ConsumerStatefulWidget {
  const AuditLogScreen({super.key});

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  List<AuditLogEntry> _entries = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;

  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _refresh();
    _searchController.addListener(() => setState(() => _searchQuery = _searchController.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref.read(adminServiceProvider).listAuditLog();
      if (mounted) {
        setState(() {
          _entries = page.entries;
          _hasMore = page.hasMore;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Failed to load the audit log. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // The collection has no retention policy (see listAuditLog's own doc
  // comment in admin.ts) — it only grows, so this is what keeps anything
  // older than the first page actually reachable rather than permanently
  // stuck behind a flat limit(). Pages back from the oldest entry loaded
  // so far, appending rather than replacing.
  Future<void> _loadMore() async {
    final oldestLoadedMs = _entries.isEmpty ? null : _entries.last.timestamp?.millisecondsSinceEpoch;
    if (oldestLoadedMs == null) return;

    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final page = await ref.read(adminServiceProvider).listAuditLog(beforeTimestampMs: oldestLoadedMs);
      if (mounted) {
        setState(() {
          _entries = [..._entries, ...page.entries];
          _hasMore = page.hasMore;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Failed to load more activity. Please try again.');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  // Client-side, over whatever's already been fetched — same reasoning as
  // user_management_screen.dart's own search. Only searches loaded pages;
  // an email that only shows up further back needs Load More first.
  List<AuditLogEntry> _filteredEntries() {
    if (_searchQuery.isEmpty) return _entries;
    return _entries.where((entry) => entry.actorEmail.toLowerCase().contains(_searchQuery)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      children: [
        const Text('Audit Log', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          'User/hospital/organization/patient-record actions across all AmDash apps, most recent first.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Recent Activity', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                  IconButton(
                    onPressed: _loading ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                  ),
                ],
              ),
              if (_loading)
                const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
              else if (_error != null)
                FormMessage(text: _error!, isError: true)
              else if (_entries.isEmpty)
                const EmptyState(title: 'No activity yet', graphic: EmptyStateGraphic.chartPulse)
              else ...[
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: 'Search',
                    hintText: 'Filter by user email',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Builder(
                  builder: (context) {
                    final filtered = _filteredEntries();
                    if (filtered.isEmpty) {
                      return const EmptyState(title: 'No activity matches this search', graphic: EmptyStateGraphic.chartPulse);
                    }
                    return _AuditLogTable(entries: filtered);
                  },
                ),
                if (_hasMore) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: OutlinedButton(
                      onPressed: _loadingMore ? null : _loadMore,
                      child: _loadingMore
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Load more'),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _AuditLogTable extends StatelessWidget {
  const _AuditLogTable({required this.entries});

  final List<AuditLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;
    return Table(
      columnWidths: const {0: FixedColumnWidth(160), 1: FlexColumnWidth(2), 2: FlexColumnWidth(2), 3: FlexColumnWidth(2)},
      border: TableBorder(horizontalInside: BorderSide(color: context.palette.border)),
      children: [
        TableRow(
          children: [
            _headerCell(context, 'When'),
            _headerCell(context, 'Who'),
            _headerCell(context, 'Action'),
            _headerCell(context, 'Details'),
          ],
        ),
        for (final entry in entries)
          TableRow(
            children: [
              _cell(
                entry.timestamp != null ? _formatTimestamp(entry.timestamp!) : '—',
                color: onSurfaceVariant,
              ),
              _cell(entry.actorEmail),
              _cell(auditActionLabels[entry.action] ?? entry.action),
              _cell(_detailsText(entry), color: onSurfaceVariant),
            ],
          ),
      ],
    );
  }

  // Renders whatever's in `details` (a free-form map — see logAudit in
  // admin.ts) as "key: value, key: value" rather than a fixed per-action
  // template, since new actions/fields shouldn't require a Flutter change
  // to display sensibly.
  String _detailsText(AuditLogEntry entry) {
    final parts = <String>[
      if (entry.target != null) 'target: ${entry.target}',
      for (final e in entry.details.entries) '${e.key}: ${e.value}',
    ];
    return parts.isEmpty ? '—' : parts.join(', ');
  }

  Widget _headerCell(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(text, style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurfaceVariant)),
  );

  Widget _cell(String text, {Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(text, style: TextStyle(color: color)),
  );
}
