import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:print_server_agente/agente.dart';
import 'package:print_server_agente/src/bandeja.dart';
import 'package:print_server_agente/src/drivers/elige.dart';
import 'package:print_server_agente/src/servicio.dart';

/// Agente de print-server.
///
/// Ejecutarlo sin argumentos hace lo que haga falta: si la computadora todavía
/// no está conectada, abre el asistente en el navegador; si ya lo está pero no
/// hay servicio instalado, lo instala y arranca; si todo está en su sitio,
/// enseña el panel.
Future<void> main(List<String> args) async {
  // En Windows la salida va en la página de códigos del sistema, y quien la
  // lee por una tubería —el servicio que guarda el registro, la ventana que
  // conecta— no tiene cómo saber cuál es. Quien lanza el agente lo pide en
  // UTF-8 y así «Conexión» llega como «Conexión».
  if (Platform.environment['PRINT_AGENTE_UTF8'] == '1') {
    stdout.encoding = utf8;
    stderr.encoding = utf8;
  }

  final comando = args.isEmpty ? '' : args.first;
  final opciones = _opciones(args);

  switch (comando) {
    case '--ayuda':
    case '-h':
    case 'ayuda':
      stdout.writeln(_ayuda);

    case '--version':
      stdout.writeln('print-server-agente $agenteVersion');

    case 'configurar':
      await _configurar(opciones);

    case 'correr':
      await _correr();

    case 'impresoras':
      await _impresoras();

    case 'probar':
      await _probar(opciones['impresora'] ?? '', opciones['protocolo']);

    case 'imprimir':
      await _imprimirArchivo(opciones);

    case 'instalar':
      await _servicio(
        () => Servicio.instala(ConfigAgente.carga()),
        'Servicio instalado.',
      );

    case 'desinstalar':
      await _servicio(Servicio.desinstala, 'Servicio desinstalado.');

    case 'bandeja':
      await _bandeja();

    case 'panel':
      _abreNavegador('http://127.0.0.1:${ConfigAgente.carga().puertoPanel}');

    case '':
      await _porDefecto();

    default:
      stderr.writeln('No conozco «$comando».\n\n$_ayuda');
      exitCode = 64;
  }
}

const _ayuda = '''
print-server-agente — imprime en esta computadora lo que le manda el hub.

  (sin argumentos)     Instala o abre el panel, según haga falta
  configurar           --hub <url> --llave <cpk_...> [--nombre <texto>]
  correr               Trabaja en primer plano (es lo que hace el servicio)
  instalar             Deja el agente arrancando con la máquina (Linux y
                       macOS; en Windows lo instala la ventana, print-server.exe)
  desinstalar          Lo quita
  impresoras           Enseña lo que ve del sistema
  probar               --impresora <nombre> [--protocolo driver|zpl|epl|dp|texto]:
                       la página de prueba, en el protocolo de esa impresora
  imprimir             --impresora <nombre> --archivo <ruta> [--formato pdf|raw|…]
                       [--copias N]: manda un archivo tal cual
  bandeja              Icono junto al reloj (Windows)
  panel                Abre el panel local en el navegador

Para conectar esta computadora solo hacen falta dos cosas: la dirección del
hub y una llave de API.
''';

Map<String, String> _opciones(List<String> args) {
  final m = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--')) continue;
    final clave = args[i].substring(2);
    if (clave.contains('=')) {
      final p = clave.split('=');
      m[p.first] = p.sublist(1).join('=');
    } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      m[clave] = args[++i];
    } else {
      m[clave] = 'si';
    }
  }
  return m;
}

Future<void> _configurar(Map<String, String> o) async {
  final config = ConfigAgente.carga();
  try {
    await registraAgente(
      config,
      hub: o['hub'] ?? '',
      llave: o['llave'] ?? '',
      nombre: o['nombre'] ?? '',
    );
    stdout.writeln('Conectado a ${config.hub} como agente ${config.agente}.');
  } catch (e) {
    stderr.writeln(mensajeDeAlta(e));
    exitCode = 1;
  }
}

/// El modo de trabajo: panel local + WebSocket con el hub, hasta que lo paren.
Future<void> _correr() async {
  final config = ConfigAgente.carga();
  if (config.ilegible) {
    stderr.writeln(
      'No puedo leer la configuración (${ConfigAgente.rutaPorDefecto()}). '
      'Lleva la credencial del agente, así que es del root: usa sudo.',
    );
    exitCode = 77; // EX_NOPERM
    return;
  }
  if (!config.configurado) {
    stderr.writeln(
      'Esta computadora no está conectada a ningún hub. '
      'Usa: print-server-agente configurar --hub <url> --llave <cpk_...>',
    );
    exitCode = 78; // EX_CONFIG
    return;
  }

  final cliente = Cliente(
    config,
    eligeDriver(config),
    Hechos.abre(ConfigAgente.rutaPorDefecto()),
  );
  final panel = Panel(config, cliente);
  try {
    await panel.arranca();
  } catch (e) {
    // Que el panel no pueda abrir su puerto no puede impedir imprimir.
    log.aviso('panel', 'no pude abrir el panel local: $e');
  }

  // Windows no tiene SIGTERM: `watch()` lo rechaza de forma asíncrona, así que
  // el fallo no sale por el `catch` de aquí sino como excepción sin capturar
  // que tumba el agente recién arrancado. Se para por otro camino —`schtasks
  // /end` o cerrar la ventana— y ninguno pasa por aquí.
  final senales = [
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ];
  for (final senal in senales) {
    senal.watch().listen((_) async {
      log.info('agente', 'parando…');
      await cliente.detiene();
      await panel.detiene();
      exit(0);
    });
  }

  log.info('agente', 'agente ${config.agente} · hub ${config.hub}');
  await cliente.corre();
}

/// Instalar y desinstalar tocan el sistema, y fallan por cosas que se
/// arreglan: casi siempre falta ejecutar como administrador. Un volcado de pila
/// de Dart no dice eso, y quien instala un agente de impresión no tiene por qué
/// leerlo para enterarse.
Future<void> _servicio(Future<void> Function() accion, String hecho) async {
  try {
    await accion();
    stdout.writeln(hecho);
  } catch (e) {
    stderr.writeln('$e');
    if (Platform.isWindows) {
      stderr.writeln(
        'La tarea del sistema se crea con permisos de administrador: abre la '
        'consola con «Ejecutar como administrador» y repite el comando.',
      );
    } else {
      stderr.writeln('Hace falta root: repite el comando con sudo.');
    }
    exitCode = 1;
  }
}

Future<void> _impresoras() async {
  final driver = eligeDriver(ConfigAgente.carga());
  final lista = await driver.inventario();
  if (lista.isEmpty) {
    stdout.writeln('Ninguna impresora (driver: ${driver.nombre}).');
    return;
  }
  for (final i in lista) {
    final identidad = [
      if (i.fabricante.isNotEmpty) i.fabricante,
      if (i.conexion.isNotEmpty) i.conexion.toUpperCase(),
      if (i.serie.isNotEmpty) 'serie ${i.serie}',
    ].join(' · ');
    stdout.writeln(
      '${i.sistema.padRight(28)} ${i.estado.padRight(10)} '
      '${identidad.padRight(34)}${i.predeterminada ? '*' : ' '} ${i.detalle}',
    );
  }
}

/// La misma página de prueba que mandan el hub y el panel, en el protocolo de
/// esa impresora (o en el que se pida con `--protocolo`).
Future<void> _probar(String impresora, String? protocolo) async {
  final config = ConfigAgente.carga();
  final driver = eligeDriver(config);
  final lista = await driver.inventario();
  var destino = impresora;
  if (destino.isEmpty) {
    final pred = lista.where((i) => i.predeterminada);
    destino = pred.isNotEmpty ? pred.first.sistema : (lista.isEmpty ? '' : lista.first.sistema);
  }
  if (destino.isEmpty) {
    stderr.writeln('No hay impresoras. Usa --impresora <nombre>.');
    exitCode = 1;
    return;
  }
  ImpresoraLocal? ficha;
  for (final i in lista) {
    if (i.sistema == destino) ficha = i;
  }
  try {
    final p = await Prueba.imprime(
      driver,
      ficha,
      destino,
      delHub: protocolo,
      equipo: config.nombre,
    );
    stdout.writeln('Mandada a «$destino» (por $p).');
  } catch (e) {
    stderr.writeln('$e');
    exitCode = 1;
  }
}

/// Un archivo tal cual, sin hub. Es como se prueba el PDF por el driver en la
/// máquina Windows de la integración continua.
Future<void> _imprimirArchivo(Map<String, String> o) async {
  final impresora = o['impresora'] ?? '';
  final archivo = File(o['archivo'] ?? '');
  if (impresora.isEmpty || !archivo.existsSync()) {
    stderr.writeln('Uso: imprimir --impresora <nombre> --archivo <ruta> [--formato pdf]');
    exitCode = 64;
    return;
  }
  final formato = o['formato'] ??
      (archivo.path.toLowerCase().endsWith('.pdf') ? 'pdf' : 'raw');
  try {
    await eligeDriver(ConfigAgente.carga()).imprime(
      TrabajoLocal(
        id: -1,
        impresora: impresora,
        formato: formato,
        nombre: archivo.uri.pathSegments.last,
        contenido: archivo.readAsBytesSync(),
        copias: int.tryParse(o['copias'] ?? '') ?? 1,
      ),
    );
    stdout.writeln('Mandado a «$impresora» ($formato).');
  } catch (e) {
    stderr.writeln('$e');
    exitCode = 1;
  }
}

/// El icono junto al reloj. Corre en la sesión del usuario, no en el servicio.
Future<void> _bandeja() async {
  final config = ConfigAgente.carga();
  final bandeja = Bandeja(config);
  if (!await bandeja.arranca()) {
    stderr.writeln('Este sistema no tiene bandeja soportada; abriendo el panel.');
    _abreNavegador('http://127.0.0.1:${config.puertoPanel}');
    return;
  }
  await bandeja.espera();
}

/// Doble clic sobre el ejecutable. Aquí es donde se decide qué necesita esta
/// computadora, en vez de pedirle a nadie que recuerde un subcomando.
Future<void> _porDefecto() async {
  final config = ConfigAgente.carga();

  if (!config.configurado) {
    // Sin configurar: el panel local ES el asistente de instalación.
    final panel = Panel(config, null);
    await panel.arranca();
    stdout.writeln('Abriendo el asistente en ${panel.url}');
    _abreNavegador(panel.url);
    // Se queda vivo hasta que el asistente termine; entonces se instala solo.
    while (!ConfigAgente.carga().configurado) {
      await Future.delayed(const Duration(seconds: 1));
    }
    await panel.detiene();
    stdout.writeln('Conectado. Instalando el servicio…');
  }

  if (!Servicio.esDesarrollo) {
    try {
      await Servicio.instala(ConfigAgente.carga());
      stdout.writeln('Servicio instalado y arrancado.');
      _abreNavegador('http://127.0.0.1:${ConfigAgente.carga().puertoPanel}');
      return;
    } catch (e) {
      stderr.writeln('No pude instalar el servicio: $e');
      stderr.writeln('Sigo en primer plano.');
    }
  }
  await _correr();
}

void _abreNavegador(String url) {
  try {
    if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', url]);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else {
      Process.run('xdg-open', [url]);
    }
  } catch (_) {
    stdout.writeln('Abre esto en el navegador: $url');
  }
}
