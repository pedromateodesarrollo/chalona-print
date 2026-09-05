import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'config.dart';
import 'db.dart';
import 'log.dart';
import 'ws/agentes_ws.dart';
import 'ws/protocolo.dart';

/// Reparte trabajos a los agentes conectados.
///
/// Tres caminos llevan al mismo sitio, y esa redundancia es deliberada:
/// 1. Al crear el trabajo, si el agente está conectado, sale de una.
/// 2. Cuando un agente se conecta, se le vacía la cola pendiente.
/// 3. Un barrido periódico recoge lo que se quedó atrás por una desconexión
///    justo en medio.
///
/// **Un trabajo puede reenviarse**; por eso el agente lleva su propio registro
/// de ids ya impresos. Reenviar de más es recuperable; imprimir dos veces 300
/// etiquetas, no.
class Despachador {
  Despachador(this.bd, this.hub, this.config);

  final Bd bd;
  final HubAgentes hub;
  final Config config;
  Timer? _barrido;
  Timer? _limpieza;

  void arranca() {
    hub.alConectar = (agente) => unawaited(drena(agente));
    _barrido = Timer.periodic(const Duration(seconds: 20), (_) async {
      try {
        await vence();
        await drenaConectados();
      } catch (e) {
        log.error('cola', 'barrido falló: $e');
      }
    });

    // La limpieza va aparte y espaciada: es un barrido de tabla, no algo que
    // haga falta cada veinte segundos.
    _limpieza = Timer.periodic(const Duration(hours: 1), (_) async {
      try {
        await purga();
      } catch (e) {
        log.error('cola', 'purga falló: $e');
      }
    });
    unawaited(purga());
  }

  void detiene() {
    _barrido?.cancel();
    _limpieza?.cancel();
  }

  /// Borra el contenido de los trabajos ya terminados que pasaron del plazo.
  ///
  /// La fila se queda —el historial es lo que contesta «¿esto se imprimió?»—
  /// pero los bytes se van. Ese contenido es el documento de un cliente y, una
  /// vez impreso, guardarlo solo añade algo que perder.
  Future<void> purga() async {
    final r = await bd.filas(
      '''update print.trabajo
            set contenido = ''::bytea
          where estado in ('hecho', 'fallido', 'cancelado')
            and length(contenido) > 0
            and coalesce(terminado, actualizado) < now() - @plazo::interval
        returning id''',
      {'plazo': '${config.retencion.inMinutes} minutes'},
    );
    if (r.isNotEmpty) {
      log.info('cola', 'contenido borrado de ${r.length} trabajo(s) antiguos');
    }
  }

  /// Primera versión del agente que sabe armar el formato `prueba`.
  static const _versionPrueba = '0.2.0';

  /// Manda un trabajo concreto. Devuelve true si salió hacia el agente.
  Future<bool> despacha(int trabajo) async {
    final t = await bd.fila(
      '''select t.id, t.agente, t.formato, t.nombre, t.copias, t.opciones,
                t.contenido, i.sistema, i.nombre as impresora_nombre,
                a.version as agente_version
           from print.trabajo t
           join print.impresora i on i.id = t.impresora
           join print.agente a on a.id = t.agente
          where t.id = @i and t.estado in ('en_cola', 'enviado')''',
      {'i': trabajo},
    );
    if (t == null) return false;
    final agente = t['agente'] as int?;
    if (agente == null) return false;

    final contenido = t['contenido'];
    var bytes = contenido is Uint8List
        ? contenido
        : Uint8List.fromList((contenido as List).cast<int>());
    var formato = t['formato'] as String;

    // Un agente instalado hace meses no conoce `prueba` y lo rechazaría. Antes
    // que romperle el botón a quien no ha actualizado, se le manda una prueba
    // de texto: peor en una etiquetadora, pero honesta y sin sorpresas.
    if (formato == 'prueba' &&
        !_alMenos(t['agente_version']?.toString() ?? '', _versionPrueba)) {
      formato = 'texto';
      bytes = Uint8List.fromList(
        utf8.encode(
          'print-server\r\n${t['impresora_nombre']}\r\n'
          '${DateTime.now()}\r\nprueba de impresion\r\n\r\n\r\n\f',
        ),
      );
      log.info('cola', 'trabajo $trabajo: prueba degradada a texto (agente v${t['agente_version']})');
    }

    final salio = hub.enviar(agente, {
      'tipo': Protocolo.trabajo,
      'id': t['id'],
      'formato': formato,
      'nombre': t['nombre'],
      'impresora': t['sistema'],
      'copias': t['copias'],
      'opciones': _opciones(t['opciones']),
      'contenido_b64': base64.encode(bytes),
    });
    if (!salio) return false;

    await bd.ejecuta(
      '''update print.trabajo
            set estado = @e, enviado = now(), actualizado = now(),
                intentos = intentos + 1
          where id = @i''',
      {'i': trabajo, 'e': EstadoTrabajo.enviado},
    );
    return true;
  }

  /// Compara versiones tipo `0.2.0`. Una versión vacía —un agente que nunca
  /// llegó a saludar— cuenta como vieja, que es el lado seguro.
  bool _alMenos(String version, String minima) {
    List<int> partes(String v) => v
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final a = partes(version), b = partes(minima);
    for (var i = 0; i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      if (x != b[i]) return x > b[i];
    }
    return true;
  }

  Map<String, Object?> _opciones(Object? crudo) {
    if (crudo is Map) return crudo.cast<String, Object?>();
    if (crudo is String && crudo.isNotEmpty) {
      final d = jsonDecode(crudo);
      if (d is Map) return d.cast<String, Object?>();
    }
    return const {};
  }

  /// Le manda a un agente todo lo que tiene pendiente. Incluye lo que quedó en
  /// `enviado`: si se cayó la conexión entre el envío y el ack, nadie sabe si
  /// llegó a imprimir, y la duda la resuelve el agente con su registro local.
  Future<void> drena(int agente) async {
    final pendientes = await bd.filas(
      '''select id from print.trabajo
          where agente = @a and estado in ('en_cola', 'enviado') and expira > now()
          order by id''',
      {'a': agente},
    );
    if (pendientes.isEmpty) return;
    log.info('cola', 'agente $agente: ${pendientes.length} trabajo(s) pendientes');
    for (final p in pendientes) {
      if (!await despacha(p['id'] as int)) break;
    }
  }

  Future<void> drenaConectados() async {
    final pendientes = await bd.filas(
      '''select distinct agente from print.trabajo
          where estado = 'en_cola' and expira > now() and agente is not null''',
    );
    for (final p in pendientes) {
      final a = p['agente'] as int;
      if (hub.estaConectado(a)) await drena(a);
    }
  }

  /// Un trabajo que no salió a tiempo se da por perdido. Imprimir la orden de
  /// ayer porque la computadora estuvo apagada no le sirve a nadie, y la cola
  /// que se acumula sale toda de golpe cuando encienden.
  Future<void> vence() async {
    final vencidos = await bd.filas(
      '''update print.trabajo
            set estado = 'fallido',
                detalle = 'Expiró en cola sin poder imprimirse',
                actualizado = now(), terminado = now()
          where estado in ('en_cola', 'enviado') and expira <= now()
        returning id, org, agente''',
    );
    for (final v in vencidos) {
      await bd.ejecuta(
        '''insert into print.evento (org, trabajo, agente, tipo, detalle)
           values (@o, @t, @a, 'fallido', 'Expiró en cola')''',
        {'o': v['org'], 't': v['id'], 'a': v['agente']},
      );
    }
    if (vencidos.isNotEmpty) {
      log.aviso('cola', '${vencidos.length} trabajo(s) expiraron');
    }
  }
}
