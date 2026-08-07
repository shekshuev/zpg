import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'package:path/path.dart' as path;

ffi.DynamicLibrary _loadLibrary() {
  if (Platform.isMacOS) {
    final exePath = Platform.resolvedExecutable;
    final libPath = path.join(
      path.dirname(path.dirname(exePath)),
      'Frameworks',
      'libzpg.dylib',
    );
    return ffi.DynamicLibrary.open(libPath);
  } else if (Platform.isWindows) {
    final exePath = Platform.resolvedExecutable;
    final libPath = path.join(path.dirname(exePath), 'zpg.dll');
    return ffi.DynamicLibrary.open(libPath);
  } else {
    final exePath = Platform.resolvedExecutable;
    final libPath = path.join(path.dirname(exePath), 'lib/libzpg.so');
    return ffi.DynamicLibrary.open(libPath);
  }
}

final zpgLib = _loadLibrary();

typedef ZpgAddC = ffi.Int32 Function(ffi.Int32 a, ffi.Int32 b);
typedef ZpgAddDart = int Function(int a, int b);

final zpgTestAdd = zpgLib.lookupFunction<ZpgAddC, ZpgAddDart>('zpg_test_add');
