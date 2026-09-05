import 'dart:io';

import 'package:print_server_agente/src/config.dart';
import 'package:print_server_agente/src/driver.dart';
import 'package:print_server_agente/src/hechos.dart';
import 'package:print_server_agente/src/prueba.dart';
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

  group('página de prueba', () {
    ImpresoraLocal ficha(String modelo, {String fabricante = '', String sistema = 'cola'}) =>
        ImpresoraLocal(
          sistema: sistema,
          nombre: sistema,
          estado: Estado.lista,
          modelo: modelo,
          fabricante: fabricante,
        );

    test('reconoce las emulaciones por su nombre de fábrica', () {
      // Honeywell llama ESim a su EPL y ZSim a su ZPL; el driver de Zebra se
      // llama ZDesigner. Son las pistas que de verdad aparecen instaladas.
      expect(Prueba.lenguaje(ficha('Honeywell PC42t (203 dpi) - ESim'), ''), 'epl');
      expect(Prueba.lenguaje(ficha('Honeywell PC42t (203 dpi) - ZSim'), ''), 'zpl');
      expect(Prueba.lenguaje(ficha('ZDesigner GK420d'), ''), 'zpl');
      expect(Prueba.lenguaje(ficha('Generic / Text Only'), ''), 'texto');
    });

    test('también mira el nombre de la cola cuando no hay modelo', () {
      expect(Prueba.lenguaje(null, 'PC42t-203-ESim'), 'epl');
      expect(Prueba.lenguaje(null, 'Canon_MF450_Series'), 'texto');
    });

    test('cada lenguaje sale con su envoltura', () {
      final epl = String.fromCharCodes(Prueba.contenido(ficha('… ESim'), 'x'));
      expect(epl, startsWith('N\n'));
      expect(epl, contains('P1'));

      final zpl = String.fromCharCodes(Prueba.contenido(ficha('ZDesigner'), 'x'));
      expect(zpl, startsWith('^XA'));
      expect(zpl, contains('^XZ'));

      // El texto acaba en avance de página; sin él la hoja se queda dentro.
      final texto = String.fromCharCodes(Prueba.contenido(ficha('Generic'), 'x'));
      expect(texto, contains('print-server'));
      expect(texto, endsWith('\f'));
    });

    test('un nombre con comillas no rompe el comando EPL', () {
      // En EPL las comillas delimitan el dato: una dentro parte el comando y
      // la impresora escupe basura o nada.
      final epl = String.fromCharCodes(
        Prueba.contenido(ficha('ESim', sistema: 'la "buena"'), 'la "buena"'),
      );
      expect(epl.split('\n').where((l) => l.startsWith('A')).length, greaterThan(2));
      expect(epl, isNot(contains('"la "buena""')));
    });

    test('un nombre largo se recorta sin salirse de latin1', () {
      // El recorte remataba con puntos suspensivos, que no existen en latin1:
      // la prueba de la PC42t —32 caracteres de nombre— moría al construirse,
      // sin llegar al spooler y sin que nadie supiera por qué.
      const cola = 'Honeywell PC42t (203 dpi) - ESim';
      final epl = String.fromCharCodes(
        Prueba.contenido(ficha('ESim', sistema: cola), cola),
      );
      expect(epl, contains('Honeywell PC42t (203 dpi) -...'));
      expect(epl, isNot(contains('…')));
    });

    test('un nombre con caracteres raros tampoco rompe nada', () {
      // El nombre de la cola lo escribe quien instaló la impresora.
      const cola = 'Etiquetas ✓ recepción';
      expect(
        () => Prueba.contenido(ficha('ESim', sistema: cola), cola),
        returnsNormally,
      );
    });
  });

  group('registro de lo ya impreso', () {
    late Directory temporal;

    setUp(() => temporal = Directory.systemTemp.createTempSync('print-server'));
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
