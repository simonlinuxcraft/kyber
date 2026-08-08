import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/features/mods/services/mod_service.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/main.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class CollectionEditorCubit extends Cubit<CollectionEditorState> {
  CollectionEditorCubit({
    ModCollectionMetaData? initialCollection,
    bool editing = false,
  }) : super(
         CollectionEditorState(
           selectedCollection: initialCollection?.copyWith(
             mods: List<CollectionMod>.from(initialCollection.mods),
           ),
           editing: editing,
         ),
       );

  void selectCollection(ModCollectionMetaData? collection) {
    emit(
      CollectionEditorState(
        selectedCollection: collection?.copyWith(
          mods: List<CollectionMod>.from(collection.mods),
        ),
      ),
    );
  }

  void createCollection({List<FrostyMod>? initialMods}) {
    emit(
      CollectionEditorState(
        editing: true,
        selectedCollection: ModCollectionMetaData(
          localId: const Uuid().v4(),
          title: 'New Collection',
          mods: [],
        ),
      ),
    );

    if (initialMods != null) {
      initialMods.forEach(addMod);
    }
  }

  bool containsMod(FrostyMod mod) {
    final collection = state.selectedCollection;
    if (collection == null) {
      return false;
    }

    return collection.mods.any(
      (c) => c.name == mod.details.name && c.version == mod.details.version,
    );
  }

  void changeCosmeticOnly({required bool enabled}) {
    final collection = state.selectedCollection;
    if (collection == null) {
      return;
    }

    collection.isCosmetic = enabled;
    emit(
      CollectionEditorState(
        selectedCollection: collection,
        editing: state.editing,
      ),
    );
  }

  void changeTitle(String title) {
    final collection = state.selectedCollection;
    if (collection == null || !state.editing) {
      return;
    }

    collection.title = title;
    emit(CollectionEditorState(selectedCollection: collection, editing: true));
  }

  void changeIcon(Uint8List? icon) {
    final collection = state.selectedCollection;
    if (collection == null || !state.editing) {
      return;
    }

    collection.icon = icon;
    emit(CollectionEditorState(selectedCollection: collection, editing: true));
  }

  Future<void> addMod(
    FrostyMod mod, {
    bool force = false,
    bool save = false,
  }) async {
    final collection = state.selectedCollection;
    if ((collection == null || !state.editing) && !force) {
      return;
    }

    if (save) {
      await saveCollection();
    }

    collection?.mods.add(mod.toCollectionMod());
    emit(
      CollectionEditorState(
        selectedCollection: collection,
        editing: !force ? true : state.editing,
      ),
    );
  }

  void moveMod(int oldIndex, int newIndex) {
    final collection = state.selectedCollection;
    if (collection == null || !state.editing) {
      return;
    }

    if (newIndex >= oldIndex) {
      newIndex -= 1;
    }

    final mod = collection.mods.removeAt(oldIndex);
    collection.mods.insert(newIndex, mod);
    emit(CollectionEditorState(selectedCollection: collection, editing: true));
  }

  Future<void> removeMod(int index) async {
    final collection = state.selectedCollection;
    if (collection == null || !state.editing) {
      return;
    }

    final mod = collection.mods.removeAt(index);
    if (sl
        .get<ModService>()
        .hiddenMods
        .where((e) => mod.filename == e.filename)
        .isNotEmpty) {
      await File(p.join(ModService.getBasePath(), mod.filename!)).delete();
      await saveCollection();
    }

    emit(CollectionEditorState(selectedCollection: collection, editing: true));
  }

  /// Drops every generated saber pack from the collection.
  ///
  /// Regenerating writes a differently stamped file each time, so the old
  /// entry has to go or the collection grows a new one per run. Two reasons
  /// this cannot use [removeMod]: that one bails out unless the collection is
  /// in edit mode, and it only ever removes a single entry, which leaves
  /// earlier ones behind once more than one has piled up.
  Future<void> removeGeneratedSaberPacks() async {
    final collection = state.selectedCollection;
    if (collection == null) return;

    final before = collection.mods.length;
    collection.mods.removeWhere(
      (mod) => mod.filename?.contains('.bsm.') ?? false,
    );
    if (collection.mods.length == before) return;

    await collectionBox.put(collection.localId, collection);
    emit(
      CollectionEditorState(
        selectedCollection: collection,
        editing: state.editing,
      ),
    );
  }

  void clearCollection() {
    emit(CollectionEditorState());
  }

  void editCollection() {
    emit(
      CollectionEditorState(
        selectedCollection: state.selectedCollection,
        editing: true,
      ),
    );
  }

  void cancelEdit() {
    emit(CollectionEditorState(selectedCollection: state.selectedCollection));
  }

  bool hasUnsavedChanges() {
    if (!state.editing) {
      return false;
    }

    final collection = state.selectedCollection!;
    final savedCollection = collectionBox.get(collection.localId);
    return collection.title != savedCollection?.title ||
        collection.description != savedCollection?.description ||
        !const ListEquality<CollectionMod>().equals(
          collection.mods,
          savedCollection?.mods,
        );
  }

  Future<void> saveCollection() async {
    final collection = state.selectedCollection;
    if (collection == null) {
      return;
    }

    await collectionBox.put(
      state.selectedCollection!.localId,
      state.selectedCollection!,
    );
    emit(CollectionEditorState(selectedCollection: collection));
  }
}

class CollectionEditorState {
  CollectionEditorState({this.selectedCollection, this.editing = false});

  final ModCollectionMetaData? selectedCollection;
  final bool editing;
}
