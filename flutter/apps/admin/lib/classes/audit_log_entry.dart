/// Mirrors what `listAuditLog` (`functions/src/admin.ts`) returns for each
/// entry — admin.ts's own mutations only, most recent first.
class AuditLogEntry {
  const AuditLogEntry({
    required this.id,
    required this.action,
    required this.actorEmail,
    required this.target,
    required this.details,
    required this.timestamp,
  });

  factory AuditLogEntry.fromJson(Map<Object?, Object?> json) {
    final timestampMs = json['timestampMs'] as num?;
    final details = json['details'];
    return AuditLogEntry(
      id: json['id'] as String? ?? '',
      action: json['action'] as String? ?? '',
      actorEmail: json['actorEmail'] as String? ?? '',
      target: json['target'] as String?,
      details: details is Map ? details.map((key, value) => MapEntry(key.toString(), value)) : const {},
      timestamp: timestampMs != null ? DateTime.fromMillisecondsSinceEpoch(timestampMs.toInt()) : null,
    );
  }

  final String id;
  final String action;
  final String actorEmail;
  final String? target;
  final Map<String, Object?> details;
  final DateTime? timestamp;
}

/// `action` (e.g. `user.roleAdd`) -> a short human label for the table.
/// Kept as a lookup rather than titlecasing the raw string, since a couple
/// (`user.roleAdd`/`user.roleRemove`) read better hand-written.
const auditActionLabels = {
  'user.create': 'Created user',
  'user.update': 'Updated user',
  'user.delete': 'Deleted user',
  'user.disable': 'Suspended user',
  'user.enable': 'Reactivated user',
  'user.resendInvite': 'Resent invite',
  'user.roleAdd': 'Assigned role',
  'user.roleRemove': 'Removed role',
  'hospital.create': 'Added hospital',
  'hospital.delete': 'Deleted hospital',
  'organization.create': 'Created organization',
  'organization.setRetention': 'Changed data retention',
};
