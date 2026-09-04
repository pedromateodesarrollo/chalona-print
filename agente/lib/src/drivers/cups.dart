import 'dart:io';

import '../driver.dart';

/// Driver para todo lo que hable CUPS: Linux y macOS.
///
/// Se apoya en `lp` y `lpstat` en vez de en la librería de C. Las dos vienen
/// con el sistema, no hay que compilar nada, y CUPS ya trae los filtros que
/// convierten PDF e imágenes a lo que entienda la impresora — que es lo que
/// hace que aquí «imprimir de todo» salga gratis y en Windows no.
class DriverCups implements Driver {
  @override
  String get nombre => 'cups';

  @override
  Future<List<ImpresoraLocal>> inventario() async {
    final estado = await _corre('lpstat', ['-p']);
    if (estado == null) return const [];
    final predeterminada = _predeterminada(await _corre('lpstat', ['-d']));

    // `lpstat -p` escribe una línea por impresora y, cuando algo va mal, una
    // segunda línea sangrada con el motivo («Unplugged or turned off»). Esa
    // segunda línea es justo la que le sirve a quien tiene que arreglarlo, así
    // que se recoge y se pega a la impresora anterior.
    final impresoras = <ImpresoraLocal>[];
    final motivos = <String, String>{};
    final crudos = <String, String>{};

    for (final lineaCruda in estado.split('\n')) {
      final linea = lineaCruda.trimRight();
      if (linea.trim().isEmpty) continue;
      final m = RegExp(r'^printer\s+(\S+)\s+(.*)$').firstMatch(linea.trim());
      if (m == null) {
        if (impresoras.isNotEmpty) {
          motivos[impresoras.last.sistema] = linea.trim();
        }
        continue;
      }
      final sistema = m.group(1)!;
      final resto = m.group(2)!.trim();
      crudos[sistema] = resto;
      impresoras.add(
        ImpresoraLocal(
          sistema: sistema,
          nombre: sistema,
          estado: _traduce(resto.toLowerCase()),
          cola: await _pendientes(sistema),
          predeterminada: sistema == predeterminada,
          // CUPS acepta los cuatro: `-o raw` pasa los bytes tal cual y sin esa
          // opción sus filtros se encargan del PDF y de las imágenes.
          formatos: const ['raw', 'pdf', 'imagen', 'texto'],
        ),
      );
    }

    // Se rehacen con el motivo ya conocido; `ImpresoraLocal` es inmutable.
    //
    // El motivo pesa más que el estado de la cola: «disabled» solo dice que la
    // cola está parada, mientras que «Unplugged or turned off» dice qué hacer.
    return impresoras
        .map(
          (i) => ImpresoraLocal(
            sistema: i.sistema,
            nombre: i.nombre,
            estado: motivos.containsKey(i.sistema)
                ? _traduce('${motivos[i.sistema]!.toLowerCase()} ${i.estado}')
                : i.estado,
            detalle: motivos[i.sistema] ??
                (i.estado == Estado.lista ? '' : crudos[i.sistema] ?? ''),
            cola: i.cola,
            predeterminada: i.predeterminada,
            formatos: i.formatos,
          ),
        )
        .toList();
  }

  @override
  Future<void> imprime(TrabajoLocal t) async {
    final args = <String>[
      '-d', t.impresora,
      '-n', '${t.copias}',
      if (t.nombre.isNotEmpty) ...['-t', t.nombre],
      // `raw` es literal: la impresora recibe exactamente los bytes. Es lo que
      // hace falta para ZPL o ESC/POS, donde un filtro por medio los destroza.
      if (t.formato == 'raw') ...['-o', 'raw'],
      ...t.opciones.entries
          .where((e) => e.key.startsWith('cups.'))
          .expand((e) => ['-o', '${e.key.substring(5)}=${e.value}']),
    ];

    final proceso = await Process.start('lp', args);
    proceso.stdin.add(t.contenido);
    await proceso.stdin.flush();
    await proceso.stdin.close();
    final salida = await proceso.stderr.transform(const SystemEncoding().decoder).join();
    final codigo = await proceso.exitCode;
    if (codigo != 0) {
      throw ErrorImpresion(
        salida.trim().isEmpty ? 'lp terminó con código $codigo' : salida.trim(),
      );
    }
  }

  /// Traduce lo que dice `lpstat` a los estados del hub.
  ///
  /// El orden importa: «is idle. disabled since…» lleva las dos palabras, y lo
  /// que manda es que la cola está parada, no que no haya nada imprimiéndose.
  String _traduce(String crudo) {
    if (crudo.contains('out of paper') || crudo.contains('media-empty')) {
      return Estado.sinPapel;
    }
    if (crudo.contains('unable') || crudo.contains('offline') ||
        crudo.contains('unplugged')) {
      return Estado.error;
    }
    if (crudo.contains('disabled') || crudo.contains('paused') ||
        crudo.contains('stopped')) {
      return Estado.pausada;
    }
    if (crudo.contains('printing') || crudo.contains('processing')) {
      return Estado.ocupada;
    }
    if (crudo.contains('idle')) return Estado.lista;
    return Estado.desconocida;
  }

  String? _predeterminada(String? salida) {
    if (salida == null) return null;
    final m = RegExp(r'destination:\s*(\S+)').firstMatch(salida);
    return m?.group(1);
  }

  Future<int> _pendientes(String impresora) async {
    final s = await _corre('lpstat', ['-o', impresora]);
    if (s == null || s.trim().isEmpty) return 0;
    return s.trim().split('\n').where((l) => l.trim().isNotEmpty).length;
  }

  Future<String?> _corre(String bin, List<String> args) async {
    try {
      final r = await Process.run(bin, args);
      // `lpstat -p` sale con 1 cuando no hay ninguna impresora; eso no es un
      // fallo, es un almacén al que todavía no le han conectado nada.
      return r.stdout.toString();
    } on ProcessException {
      return null;
    }
  }
}
