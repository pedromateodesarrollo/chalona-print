import 'dart:convert';
import 'dart:typed_data';

/// La página de prueba del camino del driver, como PDF.
///
/// Se escribe a mano —son seis objetos— para no traer una librería de PDF al
/// agente: va a computadoras ajenas y cada dependencia es superficie. Usa las
/// dos Helvetica que trae todo lector de PDF, así que no hay fuente que
/// incrustar.
///
/// Sale del tamaño del papel que tiene puesto la cola, para que se vea entera.
/// En una etiqueta más larga que ancha el texto corre a lo largo, como en las
/// etiquetas del WMS: atravesado, en 54 mm no cabría ni el nombre de la
/// impresora.
Uint8List pdfDePrueba({
  required double ancho,
  required double alto,
  required String impresora,
  String equipo = '',
  DateTime? cuando,
}) {
  final hora = cuando ?? DateTime.now();
  final girada = alto > ancho * 1.3;
  // El marco de dibujo: a lo largo si es una etiqueta alargada.
  final (w, h) = girada ? (alto, ancho) : (ancho, alto);
  final margen = (w < h ? w : h) * 0.08;

  final lineas = <(String, bool, double)>[
    ('print-server', true, 1.0),
    ('Página de prueba por el driver', false, 0.55),
    (impresora, true, 0.55),
    if (equipo.isNotEmpty) (equipo, false, 0.45),
    (_fecha(hora), false, 0.45),
    ('Si se lee entera, esta impresora imprime PDF.', false, 0.45),
  ];

  // El tamaño de cada renglón: lo que dé el alto repartido por pesos, y no más
  // de lo que deje caber su texto a lo ancho (Helvetica ~0,6 de ancho medio).
  final util = w - margen * 2;
  final pesoTotal = lineas.fold<double>(0, (s, l) => s + l.$3 * 1.25);
  final base = (h - margen * 2) / pesoTotal;
  final titulo = _min(base, util / (lineas.first.$1.length * 0.6));
  // Ninguno más grande que su peso respecto al título: en una carta el alto
  // sobra y una fecha corta saldría más grande que el nombre.
  final tamanos = [
    for (final l in lineas)
      _min(_min(base * l.$3, titulo * l.$3), util / (l.$1.length * 0.6)),
  ];

  final cs = StringBuffer();
  if (girada) cs.write('0 -1 1 0 0 ${_n(alto)} cm\n');
  // El marco: que se vea si el driver recorta un borde.
  cs.write('2 w ${_n(margen / 2)} ${_n(margen / 2)} ${_n(w - margen)} ${_n(h - margen)} re S\n');
  var y = h - margen;
  for (var i = 0; i < lineas.length; i++) {
    final t = tamanos[i];
    y -= t;
    cs.write('BT /${lineas[i].$2 ? 'F1' : 'F2'} ${_n(t)} Tf '
        '${_n(margen)} ${_n(y)} Td (${_cadena(lineas[i].$1)}) Tj ET\n');
    y -= t * 0.35;
  }

  final contenido = latin1.encode(cs.toString());
  final objetos = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${_n(ancho)} ${_n(alto)}] '
        '/Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  ];

  final out = BytesBuilder();
  final desplazamientos = <int>[];
  void escribe(String s) => out.add(latin1.encode(s));
  escribe('%PDF-1.4\n');
  for (var i = 0; i < objetos.length; i++) {
    desplazamientos.add(out.length);
    escribe('${i + 1} 0 obj\n${objetos[i]}\nendobj\n');
  }
  desplazamientos.add(out.length);
  escribe('6 0 obj\n<< /Length ${contenido.length} >>\nstream\n');
  out.add(contenido);
  escribe('endstream\nendobj\n');
  final xref = out.length;
  escribe('xref\n0 7\n0000000000 65535 f \n');
  for (final d in desplazamientos) {
    escribe('${d.toString().padLeft(10, '0')} 00000 n \n');
  }
  escribe('trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return out.toBytes();
}

double _min(double a, double b) => a < b ? a : b;

String _n(double v) => v.toStringAsFixed(2);

/// Una cadena de PDF: paréntesis y barra escapados, y lo que no es latin-1
/// cambiado por `?` (la Helvetica de serie no trae más).
String _cadena(String s) => s
    .replaceAll(RegExp(r'[^\x20-\xFF]'), '?')
    .replaceAll('\\', '\\\\')
    .replaceAll('(', '\\(')
    .replaceAll(')', '\\)');

String _fecha(DateTime d) {
  String dos(int n) => n.toString().padLeft(2, '0');
  return '${dos(d.day)}/${dos(d.month)}/${d.year} ${dos(d.hour)}:${dos(d.minute)}';
}
