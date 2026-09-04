import 'dart:typed_data';

/// Una impresora tal como la ve el sistema operativo de esta computadora.
class ImpresoraLocal {
  const ImpresoraLocal({
    required this.sistema,
    required this.nombre,
    required this.estado,
    this.detalle = '',
    this.cola = 0,
    this.predeterminada = false,
    this.formatos = const ['raw'],
    this.fabricante = '',
    this.modelo = '',
    this.conexion = '',
    this.serie = '',
  });

  /// El nombre con el que la conoce el spooler. Es la llave real.
  final String sistema;
  final String nombre;
  final String estado;
  final String detalle;
  final int cola;
  final bool predeterminada;

  /// Qué sabe mandarle este driver a esta impresora. Se reporta al hub para
  /// que rechace un PDF antes de encolarlo, y no después de que nadie imprima.
  final List<String> formatos;

  /// Quién la fabrica, qué modelo es, cómo está enchufada y su número de serie.
  ///
  /// Nada de esto hace falta para imprimir: hace falta para **reconocerla**.
  /// «PC42t-203-ESim» es el nombre de una cola; «Honeywell · USB · serie
  /// 16207B3617» es la impresora que alguien acaba de conectar y está mirando.
  final String fabricante;
  final String modelo;

  /// `usb`, `red` u `otro`.
  final String conexion;
  final String serie;

  Map<String, Object?> aJson() => {
    'sistema': sistema,
    'nombre': nombre,
    'estado': estado,
    'detalle': detalle,
    'cola': cola,
    'predeterminada': predeterminada,
    'formatos': formatos,
    'fabricante': fabricante,
    'modelo': modelo,
    'conexion': conexion,
    'serie': serie,
  };
}

/// Estados que reporta el agente. Mismos nombres que usa el hub.
class Estado {
  Estado._();
  static const lista = 'lista';
  static const ocupada = 'ocupada';
  static const pausada = 'pausada';
  static const sinPapel = 'sin_papel';
  static const error = 'error';
  static const desconocida = 'desconocida';
}

/// Lo que hay que imprimir.
class TrabajoLocal {
  const TrabajoLocal({
    required this.id,
    required this.impresora,
    required this.formato,
    required this.contenido,
    this.nombre = '',
    this.copias = 1,
    this.opciones = const {},
  });

  final int id;
  final String impresora;
  final String formato;
  final Uint8List contenido;
  final String nombre;
  final int copias;
  final Map<String, Object?> opciones;
}

/// Fallo de impresión con un mensaje que sirva para arreglarlo.
///
/// El texto llega al manager y de ahí a quien está esperando la etiqueta.
/// «PlatformException(-1)» no le dice a nadie si hay que echar papel o
/// encender la impresora.
class ErrorImpresion implements Exception {
  ErrorImpresion(this.mensaje);
  final String mensaje;
  @override
  String toString() => mensaje;
}

/// La forma de hablar con el spooler de un sistema operativo.
///
/// Hay tres implementaciones —CUPS, Windows y una falsa para pruebas— y el
/// resto del agente no sabe cuál está usando.
abstract class Driver {
  String get nombre;

  /// Qué impresoras hay y cómo están, ahora mismo.
  Future<List<ImpresoraLocal>> inventario();

  /// Manda el trabajo al spooler. Vuelve cuando el spooler lo aceptó, que no
  /// es lo mismo que cuando el papel salió: nadie puede prometer eso.
  Future<void> imprime(TrabajoLocal t);
}
