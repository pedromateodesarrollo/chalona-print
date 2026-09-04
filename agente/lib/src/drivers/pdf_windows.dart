import 'dart:io';

import '../driver.dart';
import '../log.dart';

/// Impresión de PDF e imágenes en Windows, con un ayudante externo.
///
/// El spooler de Windows no sabe qué hacer con un PDF: lo que se le manda hay
/// que dárselo ya rasterizado, y rasterizar un PDF es un motor entero. En vez
/// de meter ese motor dentro del agente —y su licencia, y su peso— se usa un
/// programa que ya esté en la máquina.
///
/// Los que se detectan solos son los dos habituales:
/// * **SumatraPDF** (`-print-to "impresora" -silent archivo`)
/// * **PDFtoPrinter** (`archivo "impresora"`)
///
/// Con `PRINT_AGENTE_AYUDANTE_PDF` se apunta a cualquier otro; se le pasan los
/// mismos argumentos que a SumatraPDF.
///
/// Si no hay ninguno, el agente **no dice que sabe imprimir PDF**: lo reporta
/// al hub y ahí se rechaza el trabajo al mandarlo, en vez de tragárselo y
/// fallar cuando ya nadie mira.
class AyudantePdfWindows {
  AyudantePdfWindows(this.ruta, this.estilo);

  final String ruta;

  /// `sumatra` o `pdftoprinter`: cambian los argumentos, no el resto.
  final String estilo;

  String get nombre => estilo;

  static AyudantePdfWindows? detecta() {
    if (!Platform.isWindows) return null;

    final forzado = Platform.environment['PRINT_AGENTE_AYUDANTE_PDF']?.trim();
    if (forzado != null && forzado.isNotEmpty && File(forzado).existsSync()) {
      final estilo = forzado.toLowerCase().contains('pdftoprinter')
          ? 'pdftoprinter'
          : 'sumatra';
      return AyudantePdfWindows(forzado, estilo);
    }

    final programas = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programasX86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final local = Platform.environment['LOCALAPPDATA'] ?? '';

    final candidatos = <MapEntry<String, String>>[
      MapEntry(r'$p\SumatraPDF\SumatraPDF.exe'.replaceAll(r'$p', programas), 'sumatra'),
      MapEntry(r'$p\SumatraPDF\SumatraPDF.exe'.replaceAll(r'$p', programasX86), 'sumatra'),
      if (local.isNotEmpty)
        MapEntry(r'$p\SumatraPDF\SumatraPDF.exe'.replaceAll(r'$p', local), 'sumatra'),
      MapEntry(r'$p\PDFtoPrinter.exe'.replaceAll(r'$p', programas), 'pdftoprinter'),
    ];

    for (final c in candidatos) {
      if (File(c.key).existsSync()) {
        log.info('windows', 'ayudante de PDF: ${c.key}');
        return AyudantePdfWindows(c.key, c.value);
      }
    }
    return null;
  }

  Future<void> imprime(TrabajoLocal t) async {
    final temporal = File(
      '${Directory.systemTemp.path}\\chalona-print-${t.id}.${t.formato == "pdf" ? "pdf" : "img"}',
    );
    temporal.writeAsBytesSync(t.contenido);
    try {
      for (var c = 0; c < t.copias; c++) {
        final args = estilo == 'pdftoprinter'
            ? [temporal.path, t.impresora]
            : ['-print-to', t.impresora, '-silent', '-exit-when-done', temporal.path];
        final r = await Process.run(ruta, args);
        if (r.exitCode != 0) {
          throw ErrorImpresion(
            'El ayudante de PDF falló (código ${r.exitCode}): ${r.stderr}',
          );
        }
      }
    } finally {
      // El archivo lleva el documento del cliente; no se queda en el temporal.
      try {
        temporal.deleteSync();
      } catch (_) {}
    }
  }
}
