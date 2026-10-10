import 'dart:convert';

import 'package:print_server_agente/agente.dart';
import 'package:print_server_agente/src/drivers/pdf_driver_windows.dart';
import 'package:print_server_agente/src/pdf_prueba.dart';
import 'package:test/test.dart';

ImpresoraLocal _imp(String modelo, {List<String> formatos = const ['raw', 'texto', 'pdf']}) =>
    ImpresoraLocal(
      sistema: modelo,
      nombre: modelo,
      estado: Estado.lista,
      modelo: modelo,
      formatos: formatos,
    );

void main() {
  group('protocolo', () {
    test('lo que fija el hub manda sobre lo que se deduce', () {
      final honeywell = _imp('Honeywell PC42t (203 dpi) - DP');
      expect(Prueba.protocolo(honeywell, honeywell.sistema), 'epl');
      expect(Prueba.protocolo(honeywell, honeywell.sistema, delHub: 'driver'), 'driver');
      expect(Prueba.protocolo(honeywell, honeywell.sistema, delHub: 'DP'), 'dp');
    });

    test('lo que no es una etiquetadora conocida va por el driver', () {
      final dymo = _imp('DYMO LabelWriter 450');
      expect(Prueba.protocolo(dymo, dymo.sistema), 'driver');
      final laser = _imp('HP LaserJet MFP M227-M231 PCL-6 (V4)');
      expect(Prueba.protocolo(laser, laser.sistema), 'driver');
    });

    test('sin PDF en esta máquina queda el texto crudo de antes', () {
      final dymo = _imp('DYMO LabelWriter 450', formatos: const ['raw', 'texto']);
      expect(Prueba.protocolo(dymo, dymo.sistema), 'texto');
    });

    test('un valor del hub que no se conoce no cuenta', () {
      final zebra = _imp('ZDesigner QLn320 (ZPL)');
      expect(Prueba.protocolo(zebra, zebra.sistema, delHub: 'braille'), 'zpl');
    });

    test('el inventario lleva el protocolo que se deduce', () {
      expect(_imp('DYMO LabelWriter 450').aJson()['protocolo'], 'driver');
    });
  });

  group('la página sobre el papel', () {
    test('una etiqueta en su propio rollo lo llena, sin bordes', () {
      // 54 × 102 mm a 300 dpi, sobre un papel que mide casi lo mismo.
      final e = encaja(paginaAncho: 638, paginaAlto: 1205, papelAncho: 638, papelAlto: 1200);
      expect(e.girada, isFalse);
      expect(e.alto, 1200);
      expect(e.x, greaterThanOrEqualTo(0));
    });

    test('apaisada sobre un rollo que avanza a lo largo, se gira en vez de encogerse', () {
      final e = encaja(paginaAncho: 1205, paginaAlto: 638, papelAncho: 638, papelAlto: 1205);
      expect(e.girada, isTrue);
      expect((e.ancho, e.alto), (638, 1205));
    });

    test('una carta sobre una etiqueta se encoge entera, centrada', () {
      final e = encaja(paginaAncho: 2550, paginaAlto: 3300, papelAncho: 638, papelAlto: 1205);
      expect(e.ancho, lessThanOrEqualTo(638));
      expect(e.alto, lessThanOrEqualTo(1205));
      expect(e.y, greaterThan(0));
    });

    test('una etiqueta sobre una carta sale a su tamaño, no estirada', () {
      final e = encaja(paginaAncho: 638, paginaAlto: 1205, papelAncho: 2550, papelAlto: 3300);
      expect((e.ancho, e.alto), (638, 1205));
    });
  });

  group('el papel del driver', () {
    const papeles = [
      PapelDriver(1, 'Letter', 2159, 2794),
      PapelDriver(262, '30252 Address', 280, 889),
      PapelDriver(270, '30323 Shipping', 540, 1016),
    ];

    test('la etiqueta de 54 × 102 mm cae en el 30323', () {
      expect(papelQueCoincide(papeles, 540, 1020)?.nombre, '30323 Shipping');
    });

    test('apaisada, el mismo papel pero girado', () {
      final p = papelQueCoincide(papeles, 1020, 540);
      expect(p?.nombre, '30323 Shipping');
      expect(p?.girado, isTrue);
    });

    test('sin ninguno que mida lo mismo, null: se pide a medida', () {
      expect(papelQueCoincide(papeles, 600, 1000), isNull);
    });
  });

  group('el PDF de prueba', () {
    test('es un PDF bien armado: la tabla de objetos apunta donde debe', () {
      final pdf = pdfDePrueba(ancho: 153.07, alto: 289.13, impresora: 'DYMO (prueba)');
      final s = latin1.decode(pdf);
      expect(s, startsWith('%PDF-1.4'));
      expect(s, contains('/MediaBox [0 0 153.07 289.13]'));
      final xref = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(s)!.group(1)!);
      expect(s.substring(xref, xref + 4), 'xref');
      // Cada objeto empieza donde dice la tabla.
      final entradas = RegExp(r'(\d{10}) 00000 n').allMatches(s).toList();
      expect(entradas, hasLength(6));
      for (var i = 0; i < entradas.length; i++) {
        final d = int.parse(entradas[i].group(1)!);
        expect(s.substring(d), startsWith('${i + 1} 0 obj'));
      }
      // El paréntesis del nombre va escapado: si no, corta la cadena.
      expect(s, contains(r'DYMO \(prueba\)'));
    });

    test('una etiqueta alargada se escribe a lo largo', () {
      final s = latin1.decode(pdfDePrueba(ancho: 153, alto: 289, impresora: 'x'));
      expect(s, contains('0 -1 1 0 0 289.00 cm'));
      final carta = latin1.decode(pdfDePrueba(ancho: 612, alto: 792, impresora: 'x'));
      expect(carta, isNot(contains(' cm\n')));
    });
  });
}
