import 'package:collection/collection.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:kyber/kyber.dart';
import 'package:kyber_launcher/core/routing/app_router.dart';
import 'package:kyber_launcher/features/kyber/providers/kyber_proxy_cubit.dart';
import 'package:kyber_launcher/features/maxima/providers/maxima_cubit.dart';

enum ModScope {
  all,
  gameplay,
  cosmetic,

  /// Mods that are installed more than once under the same name and version,
  /// which happens easily when the same mod arrives through a collection and
  /// through a separate download. Selecting them here is the way to get rid
  /// of the extra copies with the delete button.
  duplicates,
}

class ModsFilter {
  const ModsFilter({
    this.scope = ModScope.all,
    this.query,
  });

  final String? query;
  final ModScope scope;

  ModsFilter copyWith({
    String? query,
    ModScope? scope,
  }) {
    return ModsFilter(
      query: query ?? this.query,
      scope: scope ?? this.scope,
    );
  }
}
