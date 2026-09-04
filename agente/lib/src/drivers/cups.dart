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
    final dispositivos = _dispositivos(await _corre('lpstat', ['-v']));

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
          fabricante: dispositivos[sistema]?.fabricante ?? '',
          modelo: dispositivos[sistema]?.modelo ?? '',
          conexion: dispositivos[sistema]?.conexion ?? '',
          serie: dispositivos[sistema]?.serie ?? '',
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
            // Se traduce otra vez sobre el texto CRUDO más el motivo, no
            // sobre el estado ya traducido: `_traduce` entiende lo que dice
            // `lpstat`, no lo que devuelve ella misma. Pasarle su propia
            // salida dejaba en «desconocida» a toda impresora que tuviera una
            // línea de motivo.
            estado: motivos.containsKey(i.sistema)
                ? _traduce(
                    '${motivos[i.sistema]!.toLowerCase()} '
                    '${crudos[i.sistema]?.toLowerCase() ?? ''}',
                  )
                : i.estado,
            detalle: motivos[i.sistema] ??
                (i.estado == Estado.lista ? '' : crudos[i.sistema] ?? ''),
            cola: i.cola,
            predeterminada: i.predeterminada,
            formatos: i.formatos,
            fabricante: i.fabricante,
            modelo: i.modelo,
            conexion: i.conexion,
            serie: i.serie,
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

  /// Lee `lpstat -v`, que da el URI del dispositivo de cada cola:
  ///
  ///     device for PC42t-203-ESim: usb://Honeywell/PC42t-203-ESim?serial=16207B3617
  ///
  /// Ahí está lo que identifica la impresora de verdad. Se prefiere a
  /// `printer-make-and-model`, que sale del PPD y miente en cuanto alguien
  /// instala la cola con un driver genérico: en esta misma máquina, una
  /// Honeywell aparece como «HP».
  Map<String, _Dispositivo> _dispositivos(String? salida) {
    final mapa = <String, _Dispositivo>{};
    if (salida == null) return mapa;
    for (final linea in salida.split('\n')) {
      final m = RegExp(r'^device for ([^:]+): (.+)$').firstMatch(linea.trim());
      if (m == null) continue;
      mapa[m.group(1)!] = _Dispositivo.desdeUri(m.group(2)!.trim());
    }
    return mapa;
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

/// Lo que se saca del URI del dispositivo de CUPS.
class _Dispositivo {
  const _Dispositivo({
    this.fabricante = '',
    this.modelo = '',
    this.conexion = 'otro',
    this.serie = '',
  });

  final String fabricante;
  final String modelo;
  final String conexion;
  final String serie;

  factory _Dispositivo.desdeUri(String uri) {
    final u = Uri.tryParse(uri);
    if (u == null) return const _Dispositivo();
    final esquema = u.scheme.toLowerCase();

    // `usb://Fabricante/Modelo?serial=…`, leído del texto crudo y no con
    // `Uri.host`: el host de una URI se normaliza a minúsculas, y «Zebra
    // Technologies» convertido en «zebra technologies» ya no es el nombre que
    // trae la etiqueta del aparato.
    if (esquema == 'usb') {
      final m = RegExp(r'^usb://([^/]+)/([^?]*)').firstMatch(uri);
      return _Dispositivo(
        fabricante: m == null ? '' : Uri.decodeComponent(m.group(1)!),
        modelo: m == null ? '' : Uri.decodeComponent(m.group(2)!),
        conexion: 'usb',
        serie: u.queryParameters['serial'] ?? '',
      );
    }
    // Red. En `socket://192.168.1.40` el host es la dirección de la impresora
    // y sirve para reconocerla; en `implicitclass://Canon_MF450/` y en `dnssd`
    // el host es el nombre de la propia cola, así que repetirlo solo añade
    // ruido a una línea que existe para aclarar.
    const directas = ['socket', 'ipp', 'ipps', 'lpd', 'http', 'https'];
    const internas = ['dnssd', 'implicitclass'];
    if (directas.contains(esquema)) {
      return _Dispositivo(conexion: 'red', modelo: u.host);
    }
    if (internas.contains(esquema)) {
      return const _Dispositivo(conexion: 'red');
    }
    return _Dispositivo(conexion: esquema == 'file' ? 'archivo' : 'otro');
  }
}
