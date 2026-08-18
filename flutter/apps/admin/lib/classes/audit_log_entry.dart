/// Mirrors what `listAuditLog` (`functions/src/admin.ts`) returns for each
/// entry — admin.ts's own mutations plus the patient-record events logged
/// from `functions/src/patients.ts` (EMS/physician actions), most recent
/// first.
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

/// One page of `listAuditLog` results — the collection has no retention
/// policy (audit trails are meant to be kept, not minimized), so it only
/// grows; this is what lets the admin screen page back through it instead
/// of only ever being able to see the most recent 100 entries org-wide.
class AuditLogPage {
  const AuditLogPage({required this.entries, required this.hasMore});

  factory AuditLogPage.fromJson(Map<Object?, Object?> json) {
    final rawEntries = json['entries'];
    return AuditLogPage(
      entries: rawEntries is List
          ? rawEntries.whereType<Map<Object?, Object?>>().map(AuditLogEntry.fromJson).toList()
          : const [],
      hasMore: json['hasMore'] as bool? ?? false,
    );
  }

  final List<AuditLogEntry> entries;
  final bool hasMore;
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
  'hospital.update': 'Updated hospital',
  'hospital.delete': 'Deleted hospital',
  'organization.create': 'Created organization',
  'organization.setRetention': 'Changed data retention',
  'organization.setCountry': 'Set organization country',
  'organization.setCmekPreference': 'Changed KMS data residency request',
  'organization.setAuditLogging': 'Changed patient audit logging setting',
  'patient.create': 'Created patient record',
  'patient.update': 'Updated patient record',
  'patient.complete': 'Completed patient transport',
  'patient.delete': 'Deleted patient record',
  'patient.decrypt': 'Viewed decrypted patient info',
};
