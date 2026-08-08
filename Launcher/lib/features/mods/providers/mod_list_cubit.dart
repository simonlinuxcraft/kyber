import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/features/mods/constants/categories.dart';
import 'package:kyber_launcher/features/mods/extensions/frosty_collection_extension.dart';
import 'package:kyber_launcher/features/mods/helper/frosty_mod_extension.dart';
import 'package:kyber_launcher/features/mods/models/mods_filter.dart';
import 'package:kyber_launcher/features/mods/services/mod_service.dart';
import 'package:kyber_launcher/injection_container.dart';

class ModsListCubit extends Cubit<ModsListState> {
  ModsListCubit() : super(const ModsListInitial()) {
    filter = const ModsFilter();

    sl.isReady<ModService>().then((_) {
      if (isClosed) return;
      sl<ModService>().addListener(_modsChanged);
      loadMods();
    });
  }

  late ModsFilter filter;

  @override
  Future<void> close() async {
    if (sl.isReadySync<ModService>()) {
      sl<ModService>().removeListener(_modsChanged);
    }
    return super.close();
  }

  void _modsChanged() {
    loadMods();
  }

  void setFilter(ModsFilter newFilter) {
    if (newFilter == filter) return;
    filter = newFilter;
    loadMods();
  }

  void setSelectedMod(FrostyMod? selectedMod) {
    emit(
      ModsListLoaded(
        mods: state.mods,
        filter: state.filter,
        selectedMods: state.selectedMods,
        selectedMod: selectedMod,
      ),
    );
  }

  void setSelectedMods(Set<String> selectedMods) {
    emit(
      ModsListLoaded(
        mods: state.mods,
        filter: state.filter,
        selectedMods: selectedMods,
        selectedMod: state.selectedMod,
      ),
    );
  }

  Future<void> loadMods() async {
    if (!sl.isReadySync<ModService>()) {
      await sl.isReady<ModService>();
      if (isClosed) return;
    }

    final all = List<FrostyMod>.of(sl<ModService>().mods);
    final filtered = _applyFilter(all, filter);

    emit(
      ModsListLoaded(
        mods: filtered,
        filter: filter,
        selectedMods: state.selectedMods,
        selectedMod: state.selectedMod,
      ),
    );
  }

  /// Name and version identify a mod regardless of which folder it landed in,
  /// so the same mod pulled twice through different routes shares this key.
  static String _identity(FrostyMod mod) =>
      '${mod.details.name.toLowerCase()}|${mod.details.version.toLowerCase()}';

  static Set<String> _duplicateIdentities(List<FrostyMod> mods) {
    final seen = <String, int>{};
    for (final mod in mods) {
      // Packs bundle other mods and legitimately repeat their names.
      if (mod.isCollection) continue;
      final key = _identity(mod);
      seen[key] = (seen[key] ?? 0) + 1;
    }
    return seen.entries
        .where((e) => e.value > 1)
        .map((e) => e.key)
        .toSet();
  }

  List<FrostyMod> _applyFilter(List<FrostyMod> mods, ModsFilter filter) {
    final q = filter.query?.trim();
    final qLower = (q == null || q.isEmpty) ? null : q.toLowerCase();

    final duplicates = filter.scope == ModScope.duplicates
        ? _duplicateIdentities(mods)
        : const <String>{};

    final out =
        mods.where((mod) {
          var matchesSearch = true;

          if (qLower != null) {
            final modData = StringBuffer(mod.toString().toLowerCase());
            if (mod.isCollection) {
              for (final element in mod.getCollectionMods()) {
                modData.write(element.toString().toLowerCase());
              }
            }
            matchesSearch = modData.toString().contains(qLower);
          }

          final matchesScope = switch (filter.scope) {
            ModScope.all => true,
            ModScope.gameplay => kRequiredCategories.contains(
              mod.details.category.toLowerCase(),
            ),
            ModScope.cosmetic => !kRequiredCategories.contains(
              mod.details.category.toLowerCase(),
            ),
            ModScope.duplicates =>
              !mod.isCollection && duplicates.contains(_identity(mod)),
          };

          return matchesSearch && matchesScope;
        }).toList()..sort((a, b) {
          if (a.isCollection != b.isCollection) {
            return a.isCollection ? -1 : 1;
          }
          return a.details.name.compareTo(b.details.name);
        });

    final modsInCollections = (filter.scope == ModScope.all ? out : mods)
        .where((x) => x.isCollection)
        .expand((e) => e.getMods() ?? <String>[])
        .toSet();

    out.removeWhere((mod) => modsInCollections.contains(mod.filename));

    return out;
  }
}

sealed class ModsListState {
  const ModsListState({
    required this.filter,
    this.mods = const [],
    this.selectedMods = const {},
    this.selectedMod,
  });

  final ModsFilter filter;
  final List<FrostyMod> mods;
  final Set<String> selectedMods;
  final FrostyMod? selectedMod;
}

class ModsListInitial extends ModsListState {
  const ModsListInitial() : super(filter: const ModsFilter());
}

class ModsListLoaded extends ModsListState {
  const ModsListLoaded({
    required super.mods,
    required super.filter,
    required super.selectedMods,
    required super.selectedMod,
  });
}
