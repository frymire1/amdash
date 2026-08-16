/// Mirrors `libs/auth/src/lib/classes/organization.ts`.
class Organization {
  const Organization({
    required this.id,
    required this.name,
    this.retainAllData,
    this.country,
    this.cmekRequested,
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
    );
  }

  final String id;
  final String name;
  final bool? retainAllData;
  final String? country;
  final bool? cmekRequested;
}
