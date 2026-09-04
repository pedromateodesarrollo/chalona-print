import 'dart:io';

import '../config.dart';
import '../driver.dart';
import 'cups.dart';
import 'falso.dart';
import 'windows.dart';

/// Elige el driver según la configuración y el sistema.
///
/// `auto` mira el sistema operativo. Se puede forzar —`falso` para probar la
/// integración sin gastar papel— pero forzar `cups` en Windows no se permite:
/// fallaría en la primera impresión, en la máquina de un cliente, y no aquí.
Driver eligeDriver(ConfigAgente config) {
  final pedido = config.driver.trim().toLowerCase();
  final salida = config.salidaFalsa.isEmpty
      ? '${Directory.systemTemp.path}${Platform.pathSeparator}chalona-print'
      : config.salidaFalsa;

  switch (pedido) {
    case 'falso':
      return DriverFalso(salida);
    case 'cups':
      return DriverCups();
    case 'windows':
      return DriverWindows();
  }
  if (Platform.isWindows) return DriverWindows();
  return DriverCups();
}
