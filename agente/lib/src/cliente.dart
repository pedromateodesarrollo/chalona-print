import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'config.dart';
import 'driver.dart';
import 'hechos.dart';
import 'prueba.dart';
import 'log.dart';

/// Versión del protocolo que habla este agente. Ver docs/protocolo.md.
const int protocoloVersion = 1;

/// Versión del agente. Se reporta al hub y sale en el panel.
///
/// El hub la mira para no mandarle a un agente viejo algo que no entienda:
/// desde la 0.2.0 sabe armar el formato `prueba`.
const String agenteVersion = '0.2.1';

/// El agente: mantiene el WebSocket con el hub e imprime lo que llegue.
///
/// La conexión la abre el agente, siempre. Así la computadora del almacén no
/// necesita puerto abierto, IP fija ni VPN: sale hacia el hub como saldría un
/// navegador.
class Cliente {
  Cliente(this.config, this.driver, this.hechos);

  final ConfigAgente config;
  final Driver driver;
  final Hechos hechos;

  WebSocket? _ws;
  Timer? _latido;
  bool _parar = false;
  int _fallosSeguidos = 0;

  /// Último inventario reportado, para el panel local.
  List<ImpresoraLocal> ultimoInventario = const [];
  DateTime? conectadoDesde;
  String ultimoError = '';
  int impresos = 0;
  int fallidos = 0;

  bool get conectado => _ws?.readyState == WebSocket.open;

  Future<void> corre() async {
    while (!_parar) {
      try {
        await _sesion();
      } catch (e) {
        ultimoError = '$e';
        log.aviso('cliente', 'conexión caída: $e');
      }
      if (_parar) break;
      final espera = _espera();
      log.info('cliente', 'reintento en ${espera.inSeconds}s');
      await Future.delayed(espera);
    }
  }

  Future<void> detiene() async {
    _parar = true;
    _latido?.cancel();
    await _ws?.close();
  }

  /// Espera creciente con algo de azar. Sin el azar, veinte computadoras que
  /// perdieron la conexión a la vez —porque se cayó el enlace del almacén—
  /// vuelven todas en el mismo segundo y tumban el hub que acaba de levantarse.
  Duration _espera() {
    final base = min(30, 1 << min(_fallosSeguidos, 5));
    final jitter = Random().nextInt(1000);
    return Duration(seconds: base, milliseconds: jitter);
  }

  Future<void> _sesion() async {
    final ws = await WebSocket.connect(
      config.urlWs,
      headers: {'authorization': 'Bearer ${config.credencial}'},
    );
    _ws = ws;
    ws.pingInterval = const Duration(seconds: 30);

    final inventario = await _inventario();
    ws.add(jsonEncode({
      'tipo': 'hola',
      'protocolo': protocoloVersion,
      'version': agenteVersion,
      'plataforma': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'driver': driver.nombre,
      'impresoras': inventario.map((i) => i.aJson()).toList(),
    }));

    _latido = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!conectado) return;
      final inv = await _inventario();
      ws.add(jsonEncode({
        'tipo': 'latido',
        'impresoras': inv.map((i) => i.aJson()).toList(),
      }));
    });

    await for (final crudo in ws) {
      final d = jsonDecode(crudo.toString());
      if (d is! Map) continue;
      await _frame(ws, d.cast<String, Object?>());
    }

    _latido?.cancel();
    conectadoDesde = null;
    _ws = null;
    _fallosSeguidos++;
  }

  Future<void> _frame(WebSocket ws, Map<String, Object?> f) async {
    switch (f['tipo']) {
      case 'hola_ok':
        _fallosSeguidos = 0;
        conectadoDesde = DateTime.now();
        ultimoError = '';
        log.info('cliente', 'conectado al hub como agente ${f['agente']}');

      case 'hola_no':
        // El hub no habla nuestra versión. Reintentar no lo arregla; lo que
        // hace falta es actualizar el agente, y eso lo tiene que ver alguien.
        ultimoError =
            'El hub no acepta este agente: ${f['motivo']} '
            '(hub habla v${f['hub']}, mínima v${f['minima']}, agente v$protocoloVersion). '
            'Actualiza el agente.';
        log.error('cliente', ultimoError);
        await ws.close();

      case 'trabajo':
        await _imprime(ws, f);

      case 'cancelar':
        // Lo que ya salió, salió. Anotarlo evita imprimirlo si el hub lo
        // reenvía por una carrera entre la cancelación y la entrega.
        final id = (f['trabajo'] as num?)?.toInt();
        if (id != null) hechos.anota(id);
    }
  }

  Future<void> _imprime(WebSocket ws, Map<String, Object?> f) async {
    final id = (f['id'] as num?)?.toInt();
    if (id == null) return;

    if (hechos.contiene(id)) {
      log.info('trabajo', '$id ya se imprimió; se confirma sin repetir');
      ws.add(jsonEncode({
        'tipo': 'ack',
        'trabajo': id,
        'estado': 'hecho',
        'detalle': 'Ya se había impreso (reenvío)',
      }));
      return;
    }

    ws.add(jsonEncode({'tipo': 'ack', 'trabajo': id, 'estado': 'imprimiendo'}));

    try {
      final impresora = f['impresora']?.toString() ?? '';
      var formato = f['formato']?.toString() ?? 'raw';
      var contenido = Uint8List.fromList(
        base64.decode(f['contenido_b64']?.toString() ?? ''),
      );

      // La prueba la arma el agente, no el hub: aquí es donde se sabe si esta
      // cola habla EPL, ZPL o texto. Sale como `raw` para que nadie la toque
      // por el camino.
      if (formato == 'prueba') {
        ImpresoraLocal? ficha;
        for (final x in ultimoInventario) {
          if (x.sistema == impresora) {
            ficha = x;
            break;
          }
        }
        contenido = Prueba.contenido(ficha, impresora);
        formato = 'raw';
        log.info('trabajo', '$id: prueba en ${Prueba.lenguaje(ficha, impresora)}');
      }

      await driver.imprime(
        TrabajoLocal(
          id: id,
          impresora: impresora,
          formato: formato,
          contenido: contenido,
          nombre: f['nombre']?.toString() ?? '',
          copias: (f['copias'] as num?)?.toInt() ?? 1,
          opciones: (f['opciones'] as Map?)?.cast<String, Object?>() ?? const {},
        ),
      );
      // Se anota ANTES del ack: si el proceso muere entre una cosa y otra, el
      // hub reenviará y el registro dirá que ya salió. Al revés se imprimiría
      // dos veces.
      hechos.anota(id);
      impresos++;
      ws.add(jsonEncode({'tipo': 'ack', 'trabajo': id, 'estado': 'hecho'}));
      log.info('trabajo', '$id impreso en ${f['impresora']}');
    } catch (e) {
      fallidos++;
      ultimoError = '$e';
      ws.add(jsonEncode({
        'tipo': 'ack',
        'trabajo': id,
        'estado': 'fallido',
        'detalle': '$e',
      }));
      log.error('trabajo', '$id falló: $e');
    }
  }

  Future<List<ImpresoraLocal>> _inventario() async {
    try {
      ultimoInventario = await driver.inventario();
    } catch (e) {
      ultimoError = 'No pude leer las impresoras: $e';
      log.error('driver', ultimoError);
    }
    return ultimoInventario;
  }
}
