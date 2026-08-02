/// Mirrors `libs/auth/src/lib/classes/organization.ts`.
class Organization {
  const Organization({
    required this.id,
    required this.name,
    this.retainAllData,
  });

  factory Organization.fromFirestore(String id, Map<String, Object?> data) {
    return Organization(
      id: id,
      name: data['name'] as String? ?? '',
      retainAllData: data['retainAllData'] as bool?,
    );
  }

  final String id;
  final String name;
  final bool? retainAllData;
}
