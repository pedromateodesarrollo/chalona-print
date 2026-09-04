import 'dart:convert';
import 'dart:io';

/// Los trabajos que esta computadora ya imprimió.
///
/// Es la pieza que hace segura la reentrega. El hub reenvía lo que no le
/// ackearon —porque no sabe si llegó a imprimirse— y sin este registro, una
/// conexión que se corta en el peor momento saca las etiquetas dos veces.
/// Aquí se responde «ese ya salió» sin gastar papel.
///
/// Es un archivo de líneas con los últimos ids, no una base de datos: cabe en
/// memoria, sobrevive a un reinicio y no añade nada que instalar.
class Hechos {
  Hechos(this._archivo, {this.maximo = 5000});

  final File _archivo;
  final int maximo;
  final Set<int> _ids = {};
  final List<int> _orden = [];

  static Hechos abre(String rutaConfig, {int maximo = 5000}) {
    final archivo = File(
      '${File(rutaConfig).parent.path}${Platform.pathSeparator}hechos.txt',
    );
    final h = Hechos(archivo, maximo: maximo);
    h._carga();
    return h;
  }

  bool contiene(int id) => _ids.contains(id);

  void anota(int id) {
    if (!_ids.add(id)) return;
    _orden.add(id);
    if (_orden.length > maximo) {
      _ids.remove(_orden.removeAt(0));
      _guardaTodo();
    } else {
      try {
        _archivo.writeAsStringSync('$id\n', mode: FileMode.append, flush: true);
      } catch (_) {
        // Si no se puede escribir, el agente sigue imprimiendo; lo que se
        // pierde es la protección contra el duplicado tras un reinicio.
      }
    }
  }

  void _carga() {
    if (!_archivo.existsSync()) return;
    for (final linea in const LineSplitter().convert(_archivo.readAsStringSync())) {
      final id = int.tryParse(linea.trim());
      if (id != null && _ids.add(id)) _orden.add(id);
    }
  }

  void _guardaTodo() {
    try {
      _archivo.parent.createSync(recursive: true);
      _archivo.writeAsStringSync('${_orden.join('\n')}\n', flush: true);
    } catch (_) {}
  }
}
