import 'package:test/test.dart';

/// Copia de la comparación que usa el despachador para decidir si un agente
/// entiende un formato nuevo. Se prueba aquí porque equivocarse en un sentido
/// deja sin prueba a quien sí puede, y en el otro le manda a un agente viejo
/// algo que no sabe imprimir.
bool alMenos(String version, String minima) {
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

void main() {
  test('compara versiones de agente', () {
    expect(alMenos('0.2.0', '0.2.0'), isTrue);
    expect(alMenos('0.2.1', '0.2.0'), isTrue);
    expect(alMenos('1.0.0', '0.2.0'), isTrue);
    expect(alMenos('0.1.0', '0.2.0'), isFalse);
    expect(alMenos('0.1.9', '0.2.0'), isFalse);
  });

  test('una versión rara o vacía cuenta como vieja', () {
    // Es el lado seguro: se le manda lo que seguro entiende.
    expect(alMenos('', '0.2.0'), isFalse);
    expect(alMenos('desconocida', '0.2.0'), isFalse);
    expect(alMenos('0.2', '0.2.0'), isTrue);
  });
}
