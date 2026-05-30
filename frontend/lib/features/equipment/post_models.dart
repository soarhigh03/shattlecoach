/// Domain types for the 공동구매 / 부원 나눔 board.
///
/// Mirrors the `post_kind` and `post_status` enums in supabase/schema.sql.
library;

enum PostKind {
  /// 공식 공동구매 — executives only.
  groupBuy('group_buy', '공식 공동구매'),

  /// 부원 나눔 — any member.
  sharing('sharing', '부원 나눔');

  const PostKind(this.wire, this.label);

  final String wire;
  final String label;

  static PostKind fromWire(String value) =>
      PostKind.values.firstWhere((k) => k.wire == value);
}

enum PostStatus {
  inProgress('in_progress', '진행 중'),
  ended('ended', '종료');

  const PostStatus(this.wire, this.label);

  final String wire;
  final String label;

  static PostStatus fromWire(String value) =>
      PostStatus.values.firstWhere((s) => s.wire == value);
}

class PostImage {
  const PostImage({
    required this.id,
    required this.storagePath,
    required this.ord,
  });

  final String id;
  final String storagePath;
  final int ord;

  factory PostImage.fromJson(Map<String, dynamic> json) => PostImage(
    id: json['id'] as String,
    storagePath: json['storage_path'] as String,
    ord: (json['ord'] as num?)?.toInt() ?? 0,
  );
}

class Post {
  const Post({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.status,
    required this.authorId,
    required this.createdAt,
    this.images = const [],
  });

  final String id;
  final PostKind kind;
  final String title;
  final String body;
  final PostStatus status;
  final String authorId;
  final DateTime createdAt;
  final List<PostImage> images;

  /// First line of body — used as the subtitle in the list view.
  String get subtitle {
    final firstLine = body
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    return firstLine.trim();
  }

  factory Post.fromJson(Map<String, dynamic> json) {
    final imagesRaw = json['post_images'] as List<dynamic>?;
    final images =
        imagesRaw == null
              ? const <PostImage>[]
              : imagesRaw
                    .map((e) => PostImage.fromJson(e as Map<String, dynamic>))
                    .toList()
          ..sort((a, b) => a.ord.compareTo(b.ord));
    return Post(
      id: json['id'] as String,
      kind: PostKind.fromWire(json['kind'] as String),
      title: json['title'] as String,
      body: (json['body'] as String?) ?? '',
      status: PostStatus.fromWire(json['status'] as String),
      authorId: json['author_id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      images: images,
    );
  }
}
