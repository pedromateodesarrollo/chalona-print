import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../db.dart';
import '../log.dart';
import '../seguridad.dart';
import 'protocolo.dart';

/// Un agente conectado. Envuelve el socket para que nadie de fuera escriba
/// frames a mano.
class ConexionAgente {
  ConexionAgente(this.agente, this.org, this._ws, {required this.version});

  final int agente;
  final int org;
  final String version;
  final WebSocket _ws;

  void enviar(Map<String, Object?> frame) {
    if (_ws.readyState != WebSocket.open) return;
    _ws.add(jsonEncode(frame));
  }

  Future<void> cerrar() => _ws.close();
}

/// Registro de agentes conectados y puerta de salida hacia ellos.
///
/// El agente marca al hub, nunca al revés: por eso funciona detrás del router
/// de un cliente sin abrir un puerto, y por eso este registro es la única
/// manera de alcanzarlo.
class HubAgentes {
  HubAgentes(this.bd);

  final Bd bd;
  final Map<int, ConexionAgente> _conectados = {};

  /// Lo llama el despachador cuando un agente vuelve, para vaciarle la cola.
  void Function(int agente)? alConectar;

  bool estaConectado(int agente) => _conectados.containsKey(agente);

  /// Echa a un agente. Se usa al revocarle la credencial: si no, el socket ya
  /// abierto seguiría imprimiendo hasta que alguien apagara la computadora.
  Future<void> desconecta(int agente) async {
    final c = _conectados.remove(agente);
    await c?.cerrar();
  }
  int get cuantos => _conectados.length;

  /// Devuelve true si el frame salió. False significa agente desconectado:
  /// el trabajo se queda en cola, no se pierde.
  bool enviar(int agente, Map<String, Object?> frame) {
    final c = _conectados[agente];
    if (c == null) return false;
    c.enviar(frame);
    return true;
  }

  /// Atiende `GET /agente/ws`. Devuelve true si consumió la petición.
  Future<bool> upgrade(HttpRequest pet) async {
    if (pet.uri.path != '/agente/ws') return false;
    if (!WebSocketTransformer.isUpgradeRequest(pet)) return false;

    final credencial = _credencial(pet);
    final agente = await _autentica(credencial);
    if (agente == null) {
      pet.response.statusCode = HttpStatus.unauthorized;
      await pet.response.close();
      return true;
    }

    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(pet);
    } catch (e) {
      log.error('ws', 'upgrade falló: $e');
      return true;
    }
    // Si la computadora del cliente se apaga de golpe, el socket queda medio
    // abierto. El ping lo mata en un minuto en vez de dejar un agente fantasma
    // al que se le mandan trabajos que nadie imprime.
    ws.pingInterval = const Duration(seconds: 30);

    unawaited(_atiende(ws, agente['id'] as int, agente['org'] as int));
    return true;
  }

  String _credencial(HttpRequest pet) {
    final auth = pet.headers.value('authorization')?.trim() ?? '';
    if (auth.toLowerCase().startsWith('bearer ')) return auth.substring(7).trim();
    // También por query: hay proxies y herramientas de prueba que no dejan
    // poner cabeceras al abrir un WebSocket.
    return pet.uri.queryParameters['token']?.trim() ?? auth;
  }

  /// Credencial de agente: `cag_<id>_<secreto>`. El id va delante para buscar
  /// una sola fila en vez de comparar contra todas.
  Future<Map<String, Object?>?> _autentica(String credencial) async {
    final partes = Seguridad.partesCredencial(credencial);
    if (partes == null || partes[0] != 'cag') return null;
    final id = int.tryParse(partes[1]);
    if (id == null) return null;
    final fila = await bd.fila(
      'select id, org, credencial_hash from print.agente where id = @i',
      {'i': id},
    );
    final hash = fila?['credencial_hash'];
    if (hash is! String || hash.isEmpty) return null;
    if (!Seguridad.tokenCoincide(partes[2], hash)) return null;
    return fila;
  }

  Future<void> _atiende(WebSocket ws, int agente, int org) async {
    var presentado = false;
    try {
      await for (final crudo in ws) {
        Map<String, Object?> frame;
        try {
          final d = jsonDecode(crudo.toString());
          if (d is! Map) continue;
          frame = d.cast<String, Object?>();
        } catch (_) {
          continue;
        }
        final tipo = frame['tipo']?.toString() ?? '';

        if (!presentado && tipo != Protocolo.hola) {
          // Nada antes del saludo: el hub necesita saber qué versión habla
          // para decidir si le manda trabajos.
          continue;
        }

        switch (tipo) {
          case Protocolo.hola:
            final version = (frame['protocolo'] as num?)?.toInt() ?? 0;
            if (version < Protocolo.minima || version > Protocolo.version) {
              ws.add(jsonEncode({
                'tipo': Protocolo.holaNo,
                'motivo': 'protocolo_incompatible',
                'hub': Protocolo.version,
                'minima': Protocolo.minima,
              }));
              await ws.close();
              return;
            }
            presentado = true;
            _conectados[agente]?.cerrar();
            _conectados[agente] = ConexionAgente(
              agente,
              org,
              ws,
              version: frame['version']?.toString() ?? '',
            );
            await _marcaConectado(agente, frame);
            await _guardaImpresoras(agente, org, frame['impresoras']);
            ws.add(jsonEncode({
              'tipo': Protocolo.holaOk,
              'protocolo': Protocolo.version,
              'agente': agente,
            }));
            log.info('ws', 'agente $agente conectado (v${frame['version']})');
            alConectar?.call(agente);

          case Protocolo.latido:
          case Protocolo.impresoras:
            await _guardaImpresoras(agente, org, frame['impresoras']);

          case Protocolo.ack:
            await _ack(agente, org, frame);
        }
      }
    } catch (e) {
      log.aviso('ws', 'agente $agente cortó: $e');
    } finally {
      if (_conectados[agente] != null &&
          identical(_conectados[agente]!._ws, ws)) {
        _conectados.remove(agente);
      }
      await _marcaDesconectado(agente);
      log.info('ws', 'agente $agente desconectado');
    }
  }

  Future<void> _marcaConectado(int agente, Map<String, Object?> frame) =>
      bd.ejecuta(
        '''update print.agente
              set conectado = true,
                  ultima_conexion = now(),
                  version = @v,
                  plataforma = @p
            where id = @i''',
        {
          'i': agente,
          'v': frame['version']?.toString() ?? '',
          'p': frame['plataforma']?.toString() ?? '',
        },
      );

  Future<void> _marcaDesconectado(int agente) async {
    await bd.ejecuta(
      '''update print.agente
            set conectado = false, ultima_desconexion = now()
          where id = @i''',
      {'i': agente},
    );
    // Las impresoras no se borran: se marcan sin agente. Una impresora que
    // desaparece de la lista cada vez que apagan la computadora es una
    // impresora que nadie puede configurar por la mañana.
    await bd.ejecuta(
      '''update print.impresora
            set estado = @e, detalle = 'La computadora del agente no está conectada'
          where agente = @i''',
      {'i': agente, 'e': EstadoImpresora.sinAgente},
    );
  }

  /// Guarda el inventario que reporta el agente. Lo que ya no aparece queda
  /// como `ausente` — la fila sobrevive porque hay trabajos que la referencian.
  Future<void> _guardaImpresoras(int agente, int org, Object? crudas) async {
    if (crudas is! List) return;
    // La impresora vive en el dominio de su agente. Se lee aquí y no se confía
    // en lo que mande el agente: el dominio es una regla de acceso.
    final fila = await bd.fila(
      'select dominio from print.agente where id = @i',
      {'i': agente},
    );
    final dominio = fila?['dominio'] as int?;
    final vistos = <String>[];
    for (final c in crudas) {
      if (c is! Map) continue;
      final sistema = c['sistema']?.toString() ?? '';
      if (sistema.isEmpty) continue;
      vistos.add(sistema);
      await bd.ejecuta(
        '''insert into print.impresora
             (org, agente, dominio, sistema, nombre, estado, detalle, cola,
              predeterminada, formatos, visto)
           values (@org, @ag, @dom, @sis, @nom, @est, @det, @cola, @pred, @fmt, now())
           on conflict (agente, sistema) do update set
             estado   = excluded.estado,
             detalle  = excluded.detalle,
             cola     = excluded.cola,
             formatos = excluded.formatos,
             dominio  = excluded.dominio,
             visto    = now()''',
        {
          'org': org,
          'ag': agente,
          'dom': dominio,
          'sis': sistema,
          // El nombre solo se pone al crear: si alguien lo cambió en el
          // manager, el agente no se lo pisa en el siguiente latido.
          'nom': c['nombre']?.toString() ?? sistema,
          'est': c['estado']?.toString() ?? EstadoImpresora.desconocida,
          'det': c['detalle']?.toString() ?? '',
          'cola': (c['cola'] as num?)?.toInt() ?? 0,
          'pred': c['predeterminada'] == true,
          'fmt': ((c['formatos'] as List?) ?? const ['raw'])
              .map((f) => f.toString())
              .toList(),
        },
      );
    }
    if (vistos.isEmpty) return;
    await bd.ejecuta(
      '''update print.impresora
            set estado = @e, detalle = 'El agente ya no la ve en el sistema'
          where agente = @i and not (sistema = any(@v))''',
      {'i': agente, 'e': EstadoImpresora.ausente, 'v': vistos},
    );
  }

  /// El agente reporta qué pasó con un trabajo.
  Future<void> _ack(int agente, int org, Map<String, Object?> frame) async {
    final id = (frame['trabajo'] as num?)?.toInt();
    final estado = frame['estado']?.toString() ?? '';
    if (id == null || !EstadoTrabajo.deAgente.contains(estado)) return;
    final detalle = frame['detalle']?.toString() ?? '';

    // El `agente = @ag` del where es lo que impide que un agente toque el
    // trabajo de otro. La credencial ya dice quién es; esto lo obliga.
    await bd.ejecuta(
      '''update print.trabajo
            set estado = @e,
                detalle = @d,
                actualizado = now(),
                terminado = case when @e in ('hecho','fallido') then now() else terminado end
          where id = @i and agente = @ag and estado not in ('cancelado')''',
      {'i': id, 'ag': agente, 'e': estado, 'd': detalle},
    );
    await bd.ejecuta(
      '''insert into print.evento (org, trabajo, agente, tipo, detalle)
         values (@o, @t, @a, @tipo, @d)''',
      {'o': org, 't': id, 'a': agente, 'tipo': estado, 'd': detalle},
    );
  }
}
