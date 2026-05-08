import 'dart:io';

import 'package:ffigen/ffigen.dart';

void main() {
  final packageRoot = Platform.script.resolve('../');

  FfiGenerator(
    enums: .includeAll,
    functions: .includeAll,
    globals: .includeAll,
    macros: .includeAll,
    typedefs: .includeAll,
    structs: .includeAll,
    unnamedEnums: .includeAll,
    unions: .includeAll,
    output: Output(
      style: const DynamicLibraryBindings(),
      dartFile: packageRoot.resolve('lib/gen/generated_bindings.dart'),
    ),
    headers: Headers(
      compilerOptions: [
        '-include',
        'stdbool.h',
        '-I${packageRoot.resolve('third_party/vivox').toFilePath()}',
      ],
      entryPoints: [
        packageRoot.resolve(
          'third_party/vivox/ffigen_vivox_shim.h',
        ),
        packageRoot.resolve('third_party/unrar.h'),
      ],
    ),
  ).generate();
}
