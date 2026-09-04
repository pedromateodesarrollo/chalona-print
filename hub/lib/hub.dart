/// chalona-print — hub.
///
/// Junta las piezas: base de datos, REST, WebSocket de agentes y despachador
/// de la cola. Un solo proceso; el que se auto-hospeda no tiene que orquestar
/// nada.
library;

import 'dart:io';

import 'src/cola.dart';
import 'src/config.dart';
import 'src/db.dart';
import 'src/http/rutas_agentes.dart';
import 'src/http/rutas_auth.dart';
import 'src/http/rutas_dominios.dart';
import 'src/http/rutas_impresoras.dart';
import 'src/http/rutas_llaves.dart';
import 'src/http/rutas_trabajos.dart';
import 'src/http/servidor.dart';
import 'src/log.dart';
import 'src/ws/agentes_ws.dart';

export 'src/config.dart';
export 'src/db.dart';
export 'src/log.dart';

class Hub {
  Hub._(this.config, this.bd, this._servidor, this._cola, this._http);

  final Config config;
  final Bd bd;
  final Servidor _servidor;
  final Despachador _cola;
  final HttpServer _http;

  int get puerto => _http.port;
  Servidor get servidor => _servidor;

  static Future<Hub> arranca(Config config, {String migraciones = 'migraciones'}) async {
    final bd = await Bd.abrir(config.urlBd);
    await bd.migrar(migraciones);

    final servidor = Servidor(config, bd);
    final agentes = HubAgentes(bd);
    final cola = Despachador(bd, agentes, config);

    servidor.upgrades.add(agentes.upgrade);
    registraRutasAuth(servidor);
    registraRutasDominios(servidor);
    registraRutasAgentes(servidor, agentes);
    registraRutasImpresoras(servidor, agentes);
    registraRutasTrabajos(servidor, agentes, cola);
    registraRutasLlaves(servidor);

    // Al arrancar, ningún agente está conectado: lo que diga la base es de
    // antes del reinicio. Se limpia para no enseñar agentes fantasma.
    await bd.ejecuta('update print.agente set conectado = false');
    await bd.ejecuta(
      '''update print.impresora set estado = 'sin_agente'
          where estado not in ('ausente')''',
    );

    cola.arranca();
    final http = await servidor.escuchar();
    log.info('hub', 'escuchando en :${http.port}');
    if (config.secretoEfimero) {
      log.aviso(
        'hub',
        'PRINT_SECRETO_JWT no está definida: se generó una al vuelo, '
        'así que un reinicio cierra la sesión de todos. Fíjala en producción.',
      );
    }
    return Hub._(config, bd, servidor, cola, http);
  }

  Future<void> detiene() async {
    _cola.detiene();
    await _http.close(force: true);
    await bd.cerrar();
  }
}
