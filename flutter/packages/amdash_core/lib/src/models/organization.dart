/// Mirrors `libs/auth/src/lib/classes/organization.ts`.
class Organization {
  const Organization({
    required this.id,
    required this.name,
    this.retainAllData,
    this.country,
    this.cmekRequested,
    this.auditLoggingEnabled,
    this.fhirExportEnabled,
  });

  factory Organization.fromFirestore(String id, Map<String, Object?> data) {
    return Organization(
      id: id,
      name: data['name'] as String? ?? '',
      retainAllData: data['retainAllData'] as bool?,
      // Null for any org created before this field existed — never
      // defaulted to a guess, since it gates the Canadian data-residency
      // section and a wrong guess there would be worse than showing
      // nothing until an admin sets it explicitly.
      country: data['country'] as String?,
      cmekRequested: data['cmekRequested'] as bool?,
      auditLoggingEnabled: data['auditLoggingEnabled'] as bool?,
      fhirExportEnabled: data['fhirExportEnabled'] as bool?,
    );
  }

  final String id;
  final String name;
  final bool? retainAllData;
  final String? country;
  final bool? cmekRequested;

  // Null (never set) means enabled — see audit.ts's GATED_ACTIONS default.
  // Kept nullable here rather than defaulted in this model so
  // organization_settings_screen.dart's `?? true` stays the one visible
  // place that default lives, matching how retainAllData/cmekRequested's
  // `?? false` defaults are handled the same way there.
  final bool? auditLoggingEnabled;

  // Null (never set) means disabled — opt-in, unlike auditLoggingEnabled.
  // Same nullable-here/defaulted-at-the-call-site convention as every
  // other toggle on this class.
  final bool? fhirExportEnabled;
}
