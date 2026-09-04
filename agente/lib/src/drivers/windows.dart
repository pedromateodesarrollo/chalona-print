import '../driver.dart';
import 'pdf_windows.dart';
import 'winspool.dart';

/// Driver del spooler de Windows.
///
/// Habla con `winspool.drv` por FFI en vez de llamar a un `print.exe`: la
/// impresión RAW —ZPL, EPL, ESC/POS— es exactamente lo que no sobrevive a
/// pasar por un intermediario que «ayuda» reformateando.
///
/// Lo que Windows **no** trae es un renderizador de PDF para el spooler. Por
/// eso el PDF y las imágenes van por un ayudante externo opcional; sin él, esta
/// máquina reporta que solo admite `raw` y `texto`, y el hub rechaza el trabajo
/// antes de encolarlo en vez de fallar al final.
class DriverWindows implements Driver {
  DriverWindows() : _pdf = AyudantePdfWindows.detecta();

  final AyudantePdfWindows? _pdf;

  @override
  String get nombre => _pdf == null ? 'windows' : 'windows+${_pdf.nombre}';

  List<String> get _formatos => [
    'raw',
    'texto',
    if (_pdf != null) ...['pdf', 'imagen'],
  ];

  @override
  Future<List<ImpresoraLocal>> inventario() async {
    final predeterminada = Winspool.predeterminada();
    return Winspool.enumera()
        .map(
          (i) => ImpresoraLocal(
            sistema: i.nombre,
            nombre: i.nombre,
            estado: _estado(i),
            detalle: _detalle(i.estado),
            cola: i.trabajos,
            predeterminada: i.nombre == predeterminada,
            formatos: _formatos,
          ),
        )
        .toList();
  }

  @override
  Future<void> imprime(TrabajoLocal t) async {
    if (t.formato == 'raw' || t.formato == 'texto') {
      // Copias como documentos separados: el spooler de Windows no repite un
      // trabajo RAW por su cuenta, porque no sabe dónde acaba una etiqueta.
      for (var c = 0; c < t.copias; c++) {
        Winspool.imprimeCrudo(
          impresora: t.impresora,
          documento: t.nombre.isEmpty ? 'chalona-print' : t.nombre,
          datos: t.contenido,
        );
      }
      return;
    }

    final pdf = _pdf;
    if (pdf == null) {
      throw ErrorImpresion(
        'Esta computadora no puede imprimir ${t.formato}: Windows no renderiza '
        'PDF ni imágenes por sí solo. Instala SumatraPDF (o define '
        'PRINT_AGENTE_AYUDANTE_PDF con la ruta a un ayudante) y reinicia el agente.',
      );
    }
    await pdf.imprime(t);
  }

  String _estado(ImpresoraWin i) {
    const paused = 0x1, error = 0x2, paperJam = 0x8, paperOut = 0x10;
    const offline = 0x80, busy = 0x200, printing = 0x400;
    const notAvailable = 0x1000, doorOpen = 0x400000, noToner = 0x40000;
    final s = i.estado;
    if (s & (paperOut | paperJam) != 0) return Estado.sinPapel;
    if (s & (error | offline | notAvailable | doorOpen | noToner) != 0) {
      return Estado.error;
    }
    if (s & paused != 0) return Estado.pausada;
    if (s & (busy | printing) != 0 || i.trabajos > 0) return Estado.ocupada;
    if (s == 0) return Estado.lista;
    return Estado.desconocida;
  }

  /// Traduce los bits de estado a algo accionable. «0x10» no le dice a nadie
  /// que hay que echar papel.
  String _detalle(int estado) {
    const nombres = {
      0x1: 'en pausa',
      0x2: 'con error',
      0x8: 'papel atascado',
      0x10: 'sin papel',
      0x20: 'esperando alimentación manual',
      0x40: 'problema con el papel',
      0x80: 'apagada o desconectada',
      0x800: 'bandeja de salida llena',
      0x1000: 'no disponible',
      0x20000: 'poco tóner',
      0x40000: 'sin tóner',
      0x100000: 'necesita atención de una persona',
      0x400000: 'tapa abierta',
    };
    final partes = nombres.entries
        .where((e) => estado & e.key != 0)
        .map((e) => e.value)
        .toList();
    return partes.join(', ');
  }
}
