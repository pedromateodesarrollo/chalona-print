import 'dart:io';

import 'package:chalona_print_agente/src/config.dart';
import 'package:chalona_print_agente/src/hechos.dart';
import 'package:test/test.dart';

void main() {
  group('URLs del hub', () {
    test('http local conserva el puerto y no ensucia la ruta', () {
      final c = ConfigAgente(hub: 'http://localhost:3070');
      expect(c.urlWs, 'ws://localhost:3070/agente/ws');
    });

    test('https va a wss', () {
      final c = ConfigAgente(hub: 'https://print.chalonasoft.com');
      expect(c.urlWs, 'wss://print.chalonasoft.com/agente/ws');
    });

    test('respeta un hub que vive bajo un prefijo', () {
      final c = ConfigAgente(hub: 'https://ejemplo.com/print');
      expect(c.urlWs, 'wss://ejemplo.com/print/agente/ws');
    });
  });

  group('registro de lo ya impreso', () {
    late Directory temporal;

    setUp(() => temporal = Directory.systemTemp.createTempSync('chalona-print'));
    tearDown(() => temporal.deleteSync(recursive: true));

    // Este registro es lo único que separa un reenvío de una etiqueta doble.
    test('recuerda entre arranques', () {
      final ruta = '${temporal.path}/agente.json';
      Hechos.abre(ruta).anota(42);
      expect(Hechos.abre(ruta).contiene(42), isTrue);
      expect(Hechos.abre(ruta).contiene(43), isFalse);
    });

    test('no crece sin límite', () {
      final ruta = '${temporal.path}/agente.json';
      final h = Hechos.abre(ruta, maximo: 5);
      for (var i = 1; i <= 8; i++) {
        h.anota(i);
      }
      // Los últimos siguen; los primeros se caen por el fondo.
      expect(h.contiene(8), isTrue);
      expect(h.contiene(1), isFalse);
      expect(Hechos.abre(ruta, maximo: 5).contiene(8), isTrue);
    });
  });
}
