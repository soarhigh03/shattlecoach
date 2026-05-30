import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/auth_service.dart';
import '../../services/supabase_service.dart';
import 'post_models.dart';

/// Whether the current user is an executive. Null while loading / signed out.
final isExecutiveProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null || !SupabaseBootstrap.isInitialized) return false;
  final row = await SupabaseBootstrap.client
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .maybeSingle();
  return row?['role'] == 'executive';
});

class PostsRepository {
  PostsRepository(this._client);

  final SupabaseClient _client;
  static const _bucket = 'post-images';

  Future<List<Post>> list(PostKind kind) async {
    final rows = await _client
        .from('posts')
        .select(
          'id, kind, title, body, status, author_id, created_at, post_images(id, storage_path, ord)',
        )
        .eq('kind', kind.wire)
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) => Post.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<Post> fetch(String id) async {
    final row = await _client
        .from('posts')
        .select(
          'id, kind, title, body, status, author_id, created_at, post_images(id, storage_path, ord)',
        )
        .eq('id', id)
        .single();
    return Post.fromJson(row);
  }

  Future<String> create({
    required PostKind kind,
    required String title,
    required String body,
    required List<File> images,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw StateError('not signed in');
    final inserted = await _client
        .from('posts')
        .insert({
          'kind': kind.wire,
          'title': title,
          'body': body,
          'author_id': user.id,
        })
        .select('id')
        .single();
    final postId = inserted['id'] as String;
    await _uploadImages(postId: postId, images: images, startOrd: 0);
    return postId;
  }

  Future<void> update({
    required String postId,
    required PostKind kind,
    required String title,
    required String body,
    required List<PostImage> keepImages,
    required List<File> newImages,
  }) async {
    final existing = await _client
        .from('post_images')
        .select('id, storage_path')
        .eq('post_id', postId);
    final keepIds = keepImages.map((e) => e.id).toSet();
    final toDelete = (existing as List)
        .where((e) => !keepIds.contains(e['id']))
        .map((e) => e as Map<String, dynamic>)
        .toList();

    if (toDelete.isNotEmpty) {
      final paths = toDelete.map((e) => e['storage_path'] as String).toList();
      await _client.storage.from(_bucket).remove(paths);
      await _client
          .from('post_images')
          .delete()
          .inFilter('id', toDelete.map((e) => e['id'] as String).toList());
    }

    await _client
        .from('posts')
        .update({'kind': kind.wire, 'title': title, 'body': body})
        .eq('id', postId);

    final startOrd = keepImages.length;
    await _uploadImages(postId: postId, images: newImages, startOrd: startOrd);
  }

  Future<void> setStatus(String postId, PostStatus status) async {
    await _client
        .from('posts')
        .update({'status': status.wire})
        .eq('id', postId);
  }

  Future<void> delete(String postId) async {
    final imgs = await _client
        .from('post_images')
        .select('storage_path')
        .eq('post_id', postId);
    final paths = (imgs as List)
        .map((e) => (e as Map<String, dynamic>)['storage_path'] as String)
        .toList();
    if (paths.isNotEmpty) {
      await _client.storage.from(_bucket).remove(paths);
    }
    await _client.from('posts').delete().eq('id', postId);
  }

  String publicUrl(String storagePath) =>
      _client.storage.from(_bucket).getPublicUrl(storagePath);

  Future<void> _uploadImages({
    required String postId,
    required List<File> images,
    required int startOrd,
  }) async {
    for (var i = 0; i < images.length; i++) {
      final file = images[i];
      final ext = _extOf(file.path);
      final name = '${DateTime.now().millisecondsSinceEpoch}_$i$ext';
      final path = '$postId/$name';
      final bytes = await file.readAsBytes();
      await _client.storage
          .from(_bucket)
          .uploadBinary(
            path,
            Uint8List.fromList(bytes),
            fileOptions: FileOptions(
              contentType: _contentTypeFor(ext),
              upsert: false,
            ),
          );
      await _client.from('post_images').insert({
        'post_id': postId,
        'storage_path': path,
        'ord': startOrd + i,
      });
    }
  }

  String _extOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return '.jpg';
    return path.substring(i).toLowerCase();
  }

  String _contentTypeFor(String ext) {
    switch (ext) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.heic':
        return 'image/heic';
      case '.jpg':
      case '.jpeg':
      default:
        return 'image/jpeg';
    }
  }
}

final postsRepositoryProvider = Provider<PostsRepository>(
  (ref) => PostsRepository(SupabaseBootstrap.client),
);

/// Posts of a given kind, sorted newest first.
final postListProvider = FutureProvider.autoDispose
    .family<List<Post>, PostKind>((ref, kind) async {
      if (!SupabaseBootstrap.isInitialized) return const [];
      return ref.read(postsRepositoryProvider).list(kind);
    });

/// Single post, including images.
final postProvider = FutureProvider.autoDispose.family<Post, String>(
  (ref, id) async => ref.read(postsRepositoryProvider).fetch(id),
);
