import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'favorite_path_dao.g.dart';

@DriftAccessor(tables: [FavoritePaths])
class FavoritePathDao extends DatabaseAccessor<AppDatabase>
    with _$FavoritePathDaoMixin {
  FavoritePathDao(super.db);

  /// Watch all favorites ordered by last used.
  Stream<List<FavoritePath>> watchAllFavorites() {
    return (select(favoritePaths)
          ..orderBy([(t) => OrderingTerm.desc(t.lastUsedAt)]))
        .watch();
  }

  /// Watch favorites filtered by type.
  Stream<List<FavoritePath>> watchFavoritesByType(FavoritePathType type) {
    return (select(favoritePaths)
          ..where((t) => t.type.equalsValue(type))
          ..orderBy([(t) => OrderingTerm.desc(t.lastUsedAt)]))
        .watch();
  }

  /// Add a new favorite path.
  Future<int> insertFavorite(FavoritePathsCompanion favorite) {
    return into(favoritePaths).insert(favorite);
  }

  /// Update last used timestamp.
  Future<void> markUsed(int favoriteId) {
    return (update(favoritePaths)..where((t) => t.id.equals(favoriteId)))
        .write(FavoritePathsCompanion(lastUsedAt: Value(DateTime.now())));
  }

  /// Delete a favorite.
  Future<void> deleteFavorite(int favoriteId) {
    return (delete(favoritePaths)..where((t) => t.id.equals(favoriteId))).go();
  }
}
