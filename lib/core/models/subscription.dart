class Subscription {
  final String id;
  String name;
  final String url;
  DateTime? lastUpdated;
  int serverCount;

  // Данные из заголовка subscription-userinfo
  int? uploadBytes;
  int? downloadBytes;
  int? totalBytes;
  int? expireTimestamp; // unix timestamp

  // Строки описания из тела подписки
  List<String> description;

  Subscription({
    required this.id,
    required this.name,
    required this.url,
    this.lastUpdated,
    this.serverCount = 0,
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expireTimestamp,
    this.description = const [],
  });

  String get lastUpdatedText {
    if (lastUpdated == null) return 'Никогда';
    final diff = DateTime.now().difference(lastUpdated!);
    if (diff.inMinutes < 1) return 'Только что';
    if (diff.inHours < 1) return '${diff.inMinutes} мин. назад';
    if (diff.inDays < 1) return '${diff.inHours} ч. назад';
    return '${diff.inDays} дн. назад';
  }

  // Использованный трафик (upload + download)
  int get usedBytes => (uploadBytes ?? 0) + (downloadBytes ?? 0);

  // Осталось дней до истечения
  int? get daysLeft {
    if (expireTimestamp == null) return null;
    final expire =
        DateTime.fromMillisecondsSinceEpoch(expireTimestamp! * 1000);
    final diff = expire.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }

  DateTime? get expireDate => expireTimestamp == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expireTimestamp! * 1000);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (lastUpdated != null) 'lastUpdated': lastUpdated!.toIso8601String(),
        'serverCount': serverCount,
        if (uploadBytes != null) 'uploadBytes': uploadBytes,
        if (downloadBytes != null) 'downloadBytes': downloadBytes,
        if (totalBytes != null) 'totalBytes': totalBytes,
        if (expireTimestamp != null) 'expireTimestamp': expireTimestamp,
        if (description.isNotEmpty) 'description': description,
      };

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        id: j['id'] as String,
        name: j['name'] as String,
        url: j['url'] as String,
        lastUpdated: j['lastUpdated'] != null
            ? DateTime.parse(j['lastUpdated'] as String)
            : null,
        serverCount: j['serverCount'] as int? ?? 0,
        uploadBytes: (j['uploadBytes'] as num?)?.toInt(),
        downloadBytes: (j['downloadBytes'] as num?)?.toInt(),
        totalBytes: (j['totalBytes'] as num?)?.toInt(),
        expireTimestamp: (j['expireTimestamp'] as num?)?.toInt(),
        description: (j['description'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            [],
      );
}
