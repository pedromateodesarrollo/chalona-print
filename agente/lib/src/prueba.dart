import 'dart:convert';
import 'dart:typed_data';

import 'driver.dart';

/// Arma la página de prueba que entiende cada impresora.
///
/// Esto vive en el agente y no en el hub ni en el panel a propósito: ninguno
/// de los dos sabe si la impresora de enfrente habla EPL, ZPL o texto. Mandar
/// texto plano a una etiquetadora en modo ESim no imprime nada **y el trabajo
/// queda en «hecho»**, que es la peor combinación posible: falla en silencio.
class Prueba {
  Prueba._();

  /// Qué lenguaje habla, deducido del modelo y del nombre de la cola.
  ///
  /// Las pistas vienen del propio fabricante: Honeywell nombra sus emulaciones
  /// `ESim` (EPL) y `ZSim` (ZPL), y el driver de Zebra se llama `ZDesigner`.
  /// No es infalible —una cola renombrada a mano puede despistar— pero acierta
  /// en lo que hay instalado de verdad, y el peor caso es una hoja de texto.
  static String lenguaje(ImpresoraLocal? i, String nombreCola) {
    final pistas = [
      i?.modelo ?? '',
      i?.fabricante ?? '',
      i?.sistema ?? '',
      nombreCola,
    ].join(' ').toLowerCase();

    if (pistas.contains('zsim') ||
        pistas.contains('zpl') ||
        pistas.contains('zdesigner') ||
        pistas.contains('zebra')) {
      return 'zpl';
    }
    if (pistas.contains('esim') ||
        pistas.contains('epl') ||
        pistas.contains('eltron')) {
      return 'epl';
    }
    return 'texto';
  }

  /// El contenido de la prueba, ya en bytes listos para el spooler.
  static Uint8List contenido(ImpresoraLocal? i, String nombreCola) {
    final ahora = DateTime.now();
    final fecha =
        '${_dd(ahora.day)}/${_dd(ahora.month)}/${ahora.year}  '
        '${_dd(ahora.hour)}:${_dd(ahora.minute)}';
    final nombre = _recorta(i?.nombre ?? nombreCola, 30);

    switch (lenguaje(i, nombreCola)) {
      case 'epl':
        // Todo por encima del dot 300: hay etiquetadoras con desplazamientos
        // de origen que recortan el final, y una prueba que se sale de la
        // etiqueta deja la impresora en error justo cuando alguien está
        // comprobando que funciona.
        return Uint8List.fromList(
          latin1.encode(
            'N\n'
            'A30,30,0,4,1,1,N,"CHALONA-PRINT"\n'
            'A30,110,0,3,1,1,N,"${_epl(nombre)}"\n'
            'A30,170,0,2,1,1,N,"$fecha"\n'
            'A30,220,0,2,1,1,N,"prueba de impresion"\n'
            'P1\n',
          ),
        );

      case 'zpl':
        return Uint8List.fromList(
          latin1.encode(
            '^XA\n'
            '^FO30,30^A0N,45,45^FDCHALONA-PRINT^FS\n'
            '^FO30,100^A0N,30,30^FD${_zpl(nombre)}^FS\n'
            '^FO30,150^A0N,28,28^FD$fecha^FS\n'
            '^FO30,195^A0N,28,28^FDprueba de impresion^FS\n'
            '^XZ\n',
          ),
        );

      default:
        // Texto para impresoras de página. El avance de página al final es lo
        // que hace que la hoja salga en vez de quedarse esperando en el búfer.
        return Uint8List.fromList(
          latin1.encode(
            'chalona-print\r\n'
            '$nombre\r\n'
            '$fecha\r\n'
            'prueba de impresion\r\n'
            '\r\n\r\n\f',
          ),
        );
    }
  }

  static String _dd(int n) => n.toString().padLeft(2, '0');

  static String _recorta(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';

  /// En EPL las comillas delimitan el dato; una en el nombre parte el comando.
  static String _epl(String s) => s.replaceAll('"', "'");

  /// En ZPL, `^` y `~` son prefijos de comando.
  static String _zpl(String s) => s.replaceAll(RegExp(r'[\^~]'), '-');
}
