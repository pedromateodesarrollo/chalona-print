import 'dart:io';

import '../driver.dart';

/// Driver de mentira: escribe los trabajos en una carpeta en vez de imprimir.
///
/// Está en el producto, no en los tests, a propósito. Sirve para probar una
/// integración entera —hub, cola, agente, reintentos— sin gastar una etiqueta,
/// y para que quien monte esto por primera vez vea que funciona antes de
/// pelearse con los drivers de su impresora.
///
///   PRINT_AGENTE_DRIVER=falso  PRINT_AGENTE_SALIDA=/tmp/impresiones
class DriverFalso implements Driver {
  DriverFalso(this.carpeta);

  final String carpeta;

  @override
  String get nombre => 'falso';

  @override
  Future<List<ImpresoraLocal>> inventario() async => [
    ImpresoraLocal(
      sistema: 'falsa-etiquetas',
      nombre: 'Falsa (etiquetas)',
      estado: Estado.lista,
      detalle: 'Escribe en $carpeta',
      predeterminada: true,
      formatos: const ['raw', 'pdf', 'imagen', 'texto'],
    ),
    ImpresoraLocal(
      sistema: 'falsa-rota',
      nombre: 'Falsa (siempre falla)',
      estado: Estado.error,
      detalle: 'Existe para probar el camino del fallo',
      formatos: const ['raw', 'pdf', 'imagen', 'texto'],
    ),
  ];

  @override
  Future<void> imprime(TrabajoLocal t) async {
    if (t.impresora == 'falsa-rota') {
      throw ErrorImpresion('Impresora de prueba: falla siempre, a propósito');
    }
    final dir = Directory(carpeta)..createSync(recursive: true);
    final archivo = File(
      '${dir.path}${Platform.pathSeparator}trabajo-${t.id}.${_extension(t.formato)}',
    );
    archivo.writeAsBytesSync(t.contenido);
  }

  String _extension(String formato) => switch (formato) {
    'pdf' => 'pdf',
    'imagen' => 'img',
    'texto' => 'txt',
    _ => 'bin',
  };
}
