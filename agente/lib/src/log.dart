import 'dart:collection';
import 'dart:io';

/// Log del agente: a consola y a un anillo en memoria que lee el panel.
///
/// El anillo es lo que ve quien hace clic en el icono de la bandeja cuando
/// «no imprime»: sin eso hay que enseñarle a buscar el visor de eventos de
/// Windows, y eso no va a pasar.
class Log {
  Log._();
  static final Log _i = Log._();
  factory Log() => _i;

  final Queue<String> _ultimas = Queue<String>();
  static const _maximo = 200;

  List<String> get ultimas => _ultimas.toList();

  void info(String etiqueta, String mensaje) => _linea('info', etiqueta, mensaje);
  void aviso(String etiqueta, String mensaje) => _linea('aviso', etiqueta, mensaje);
  void error(String etiqueta, String mensaje) => _linea('error', etiqueta, mensaje);

  void _linea(String nivel, String etiqueta, String mensaje) {
    final linea =
        '${DateTime.now().toIso8601String()} $nivel [$etiqueta] $mensaje';
    _ultimas.addLast(linea);
    while (_ultimas.length > _maximo) {
      _ultimas.removeFirst();
    }
    stdout.writeln(linea);
  }
}

final log = Log();
