/// Mirrors `libs/auth/src/lib/classes/hospital.ts`.
class Hospital {
  const Hospital({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.organizationId,
  });

  factory Hospital.fromFirestore(String id, Map<String, Object?> data) {
    return Hospital(
      id: id,
      name: data['name'] as String? ?? '',
      address: data['address'] as String? ?? '',
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0,
      organizationId: data['organizationId'] as String? ?? '',
    );
  }

  final String id;
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final String organizationId;
}
