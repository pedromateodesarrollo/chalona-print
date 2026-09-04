// Los campos de las estructuras llevan el nombre exacto del API de Windows.
// Renombrarlos a estilo Dart obligaría a cotejar con la documentación de
// Microsoft cada vez que alguien revise el orden, que es justo lo que aquí
// no se puede equivocar.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../driver.dart';

/// Una impresora tal como la devuelve `EnumPrinters`.
class ImpresoraWin {
  const ImpresoraWin(this.nombre, this.estado, this.trabajos);
  final String nombre;

  /// Bits `PRINTER_STATUS_*`.
  final int estado;
  final int trabajos;
}

/// Enlace directo con el spooler de Windows (`winspool.drv`).
///
/// Son ocho funciones. Se enlazan a mano en lugar de traer un paquete de
/// bindings de Win32 entero: el agente se instala en máquinas ajenas y cada
/// dependencia es superficie que alguien tendrá que auditar.
class Winspool {
  Winspool._();

  static final DynamicLibrary _dll = DynamicLibrary.open('winspool.drv');

  static final _enumPrinters = _dll.lookupFunction<
      Int32 Function(Uint32, Pointer<Utf16>, Uint32, Pointer<Uint8>, Uint32,
          Pointer<Uint32>, Pointer<Uint32>),
      int Function(int, Pointer<Utf16>, int, Pointer<Uint8>, int,
          Pointer<Uint32>, Pointer<Uint32>)>('EnumPrintersW');

  static final _getDefaultPrinter = _dll.lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Uint32>),
      int Function(Pointer<Utf16>, Pointer<Uint32>)>('GetDefaultPrinterW');

  static final _openPrinter = _dll.lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>),
      int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>)>('OpenPrinterW');

  static final _startDocPrinter = _dll.lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<_DocInfo1>),
      int Function(int, int, Pointer<_DocInfo1>)>('StartDocPrinterW');

  static final _startPagePrinter = _dll.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('StartPagePrinter');

  static final _writePrinter = _dll.lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>)>('WritePrinter');

  static final _endPagePrinter = _dll.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('EndPagePrinter');

  static final _endDocPrinter = _dll.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('EndDocPrinter');

  static final _closePrinter = _dll.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('ClosePrinter');

  static const _enumLocal = 0x2;
  static const _enumConnections = 0x4;

  /// Las impresoras locales y las conectadas por red desde este usuario.
  ///
  /// `EnumPrinters` se llama dos veces a propósito: la primera dice cuánta
  /// memoria hace falta, la segunda la llena. Es su contrato, no un rodeo.
  static List<ImpresoraWin> enumera() {
    final necesario = calloc<Uint32>();
    final devueltas = calloc<Uint32>();
    try {
      _enumPrinters(_enumLocal | _enumConnections, nullptr, 2, nullptr, 0,
          necesario, devueltas);
      final bytes = necesario.value;
      if (bytes == 0) return const [];

      final buffer = calloc<Uint8>(bytes);
      try {
        final ok = _enumPrinters(_enumLocal | _enumConnections, nullptr, 2,
            buffer, bytes, necesario, devueltas);
        if (ok == 0) return const [];
        final info = buffer.cast<_PrinterInfo2>();
        return List.generate(devueltas.value, (i) {
          final p = (info + i).ref;
          return ImpresoraWin(
            p.pPrinterName == nullptr ? '' : p.pPrinterName.toDartString(),
            p.Status,
            p.cJobs,
          );
        }).where((p) => p.nombre.isNotEmpty).toList();
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc
        ..free(necesario)
        ..free(devueltas);
    }
  }

  static String? predeterminada() {
    final largo = calloc<Uint32>()..value = 0;
    try {
      _getDefaultPrinter(nullptr, largo);
      if (largo.value == 0) return null;
      final buffer = calloc<Uint16>(largo.value).cast<Utf16>();
      try {
        if (_getDefaultPrinter(buffer, largo) == 0) return null;
        return buffer.toDartString();
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(largo);
    }
  }

  /// Manda los bytes al spooler sin que nadie los toque (datatype `RAW`).
  ///
  /// Es el camino de las etiquetas: ZPL, EPL y ESC/POS son lenguajes que
  /// entiende la impresora, y cualquier «ayuda» del driver los rompe.
  static void imprimeCrudo({
    required String impresora,
    required String documento,
    required Uint8List datos,
  }) {
    final nombre = impresora.toNativeUtf16();
    final asa = calloc<IntPtr>();
    try {
      if (_openPrinter(nombre, asa, nullptr) == 0) {
        throw ErrorImpresion(
          'Windows no pudo abrir la impresora «$impresora». '
          'Comprueba que existe con ese nombre exacto y que el servicio tiene acceso.',
        );
      }
      final h = asa.value;
      final doc = calloc<_DocInfo1>();
      final tituloDoc = documento.toNativeUtf16();
      final tipo = 'RAW'.toNativeUtf16();
      doc.ref
        ..pDocName = tituloDoc
        ..pOutputFile = nullptr
        ..pDatatype = tipo;
      try {
        if (_startDocPrinter(h, 1, doc) == 0) {
          throw ErrorImpresion('El spooler rechazó el documento en «$impresora»');
        }
        try {
          if (_startPagePrinter(h) == 0) {
            throw ErrorImpresion('El spooler rechazó la página en «$impresora»');
          }
          final buffer = calloc<Uint8>(datos.length);
          final escritos = calloc<Uint32>();
          try {
            buffer.asTypedList(datos.length).setAll(0, datos);
            final ok = _writePrinter(h, buffer, datos.length, escritos);
            if (ok == 0 || escritos.value != datos.length) {
              throw ErrorImpresion(
                'Se enviaron ${escritos.value} de ${datos.length} bytes a «$impresora»',
              );
            }
          } finally {
            calloc
              ..free(buffer)
              ..free(escritos);
          }
          _endPagePrinter(h);
        } finally {
          _endDocPrinter(h);
        }
      } finally {
        calloc.free(doc);
        calloc
          ..free(tituloDoc)
          ..free(tipo);
        _closePrinter(h);
      }
    } finally {
      calloc
        ..free(nombre)
        ..free(asa);
    }
  }
}

/// `DOC_INFO_1W`
final class _DocInfo1 extends Struct {
  external Pointer<Utf16> pDocName;
  external Pointer<Utf16> pOutputFile;
  external Pointer<Utf16> pDatatype;
}

/// `PRINTER_INFO_2W`. El orden de los campos es el contrato con el sistema:
/// mover uno desplaza todo lo que viene detrás y se leen datos equivocados sin
/// que nada avise.
final class _PrinterInfo2 extends Struct {
  external Pointer<Utf16> pServerName;
  external Pointer<Utf16> pPrinterName;
  external Pointer<Utf16> pShareName;
  external Pointer<Utf16> pPortName;
  external Pointer<Utf16> pDriverName;
  external Pointer<Utf16> pComment;
  external Pointer<Utf16> pLocation;
  external Pointer<Void> pDevMode;
  external Pointer<Utf16> pSepFile;
  external Pointer<Utf16> pPrintProcessor;
  external Pointer<Utf16> pDatatype;
  external Pointer<Utf16> pParameters;
  external Pointer<Void> pSecurityDescriptor;
  @Uint32()
  external int Attributes;
  @Uint32()
  external int Priority;
  @Uint32()
  external int DefaultPriority;
  @Uint32()
  external int StartTime;
  @Uint32()
  external int UntilTime;
  @Uint32()
  external int Status;
  @Uint32()
  external int cJobs;
  @Uint32()
  external int AveragePPM;
}
