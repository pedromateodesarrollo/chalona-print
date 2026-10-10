import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../driver.dart';
import '../log.dart';

/// PDF por el driver de la impresora, sin programas externos.
///
/// Es el camino ESTÁNDAR: lo que hace Windows con su página de prueba y lo que
/// hace un navegador al imprimir. El PDF se le da al driver ya dibujado —el
/// motor es PDFium, el de Chrome, que viene en `pdfium.dll` junto al agente— y
/// el driver lo traduce a lo que hable la impresora. Por eso sirve una DYMO,
/// que no entiende ZPL ni EPL ni texto crudo, igual que una láser o una
/// térmica con su driver.
///
/// **El papel lo pone la página.** Antes de abrir el trabajo se busca, entre
/// los papeles que declara el driver, el que mide lo mismo que la página del
/// PDF (±3 mm): una etiqueta de 54 × 102 mm cae en el «30323 Shipping» de la
/// DYMO y no en el papel que tuviera elegido la cola. Si el driver no tiene
/// ninguno así, se le pide un tamaño a medida; y si tampoco lo acepta, la
/// página se encoge para caber en el que haya. Es lo que hace Acrobat con
/// «elegir el origen del papel por el tamaño de la página».
class PdfPorDriver {
  PdfPorDriver._(this._pdfium);

  final _Pdfium _pdfium;

  /// `pdfium.dll` junto al ejecutable (así lo deja el instalador) o donde diga
  /// `PRINT_AGENTE_PDFIUM`. Sin ella el agente no dice que sabe imprimir PDF y
  /// el hub rechaza esos trabajos al mandarlos, en vez de fallar al final.
  static PdfPorDriver? detecta() {
    if (!Platform.isWindows) return null;
    final forzada = Platform.environment['PRINT_AGENTE_PDFIUM']?.trim() ?? '';
    final candidatas = [
      if (forzada.isNotEmpty) forzada,
      '${File(Platform.resolvedExecutable).parent.path}\\pdfium.dll',
    ];
    for (final ruta in candidatas) {
      if (!File(ruta).existsSync()) continue;
      try {
        final p = PdfPorDriver._(_Pdfium(DynamicLibrary.open(ruta)));
        log.info('windows', 'PDF por el driver con $ruta');
        return p;
      } catch (e) {
        log.aviso('windows', 'no se pudo cargar $ruta: $e');
      }
    }
    return null;
  }

  /// El papel que tiene elegido la cola ahora, en puntos (1/72"). Es la
  /// medida de la página de prueba: que salga entera en lo que hay puesto.
  (double, double)? papelActual(String impresora) {
    final dm = _Devmode.porDefecto(impresora);
    if (dm == null) return null;
    final dc = _Gdi.createDC(impresora, dm.puntero);
    dm.libera();
    if (dc == 0) return null;
    try {
      final ancho = _Gdi.caps(dc, _physicalWidth);
      final alto = _Gdi.caps(dc, _physicalHeight);
      final dpiX = _Gdi.caps(dc, _logPixelsX);
      final dpiY = _Gdi.caps(dc, _logPixelsY);
      if (ancho <= 0 || alto <= 0 || dpiX <= 0 || dpiY <= 0) return null;
      return (ancho / dpiX * 72, alto / dpiY * 72);
    } finally {
      _Gdi.deleteDC(dc);
    }
  }

  /// Imprime el PDF entero en [impresora], [copias] veces.
  void imprime({
    required String impresora,
    required String documento,
    required Uint8List pdf,
    int copias = 1,
  }) {
    _pdfium.inicia();
    final datos = calloc<Uint8>(pdf.length);
    datos.asTypedList(pdf.length).setAll(0, pdf);
    final doc = _pdfium.loadMemDocument(datos.cast(), pdf.length, nullptr);
    try {
      if (doc == nullptr) {
        throw ErrorImpresion(
          'El PDF no se pudo abrir (PDFium dijo ${_pdfium.lastError()}): '
          'está dañado o no es un PDF.',
        );
      }
      final paginas = _pdfium.pageCount(doc);
      if (paginas <= 0) throw ErrorImpresion('El PDF no tiene páginas.');

      final medida = calloc<_FsSizeF>();
      try {
        _pdfium.pageSizeByIndex(doc, 0, medida);
        final dm = _Devmode.porDefecto(impresora);
        if (dm == null) {
          throw ErrorImpresion(
            'Windows no pudo abrir la impresora «$impresora». '
            'Comprueba que existe con ese nombre exacto.',
          );
        }
        try {
          final papel = _eligePapel(impresora, dm, medida.ref.width, medida.ref.height);
          log.info('windows', '«$impresora»: $papel');
          final dc = _Gdi.createDC(impresora, dm.puntero);
          if (dc == 0) {
            throw ErrorImpresion('El driver de «$impresora» no abrió el dispositivo de impresión.');
          }
          try {
            _imprimeEn(dc, doc, paginas, documento, copias, impresora);
          } finally {
            _Gdi.deleteDC(dc);
          }
        } finally {
          dm.libera();
        }
      } finally {
        calloc.free(medida);
      }
    } finally {
      if (doc != nullptr) _pdfium.closeDocument(doc);
      calloc.free(datos);
    }
  }

  void _imprimeEn(
    int dc,
    Pointer<Void> doc,
    int paginas,
    String documento,
    int copias,
    String impresora,
  ) {
    final info = calloc<_DocInfoW>();
    final titulo = (documento.isEmpty ? 'print-server' : documento).toNativeUtf16();
    info.ref
      ..cbSize = sizeOf<_DocInfoW>()
      ..lpszDocName = titulo
      ..lpszOutput = nullptr
      ..lpszDatatype = nullptr
      ..fwType = 0;
    try {
      if (_Gdi.startDoc(dc, info) <= 0) {
        throw ErrorImpresion('El spooler rechazó el documento en «$impresora».');
      }
      var terminado = false;
      try {
        final fisicoAncho = _Gdi.caps(dc, _physicalWidth);
        final fisicoAlto = _Gdi.caps(dc, _physicalHeight);
        final margenX = _Gdi.caps(dc, _physicalOffsetX);
        final margenY = _Gdi.caps(dc, _physicalOffsetY);
        final dpiX = _Gdi.caps(dc, _logPixelsX);
        final dpiY = _Gdi.caps(dc, _logPixelsY);
        // Un driver que no da el físico (raro, pero los hay) se mide por lo
        // imprimible.
        final papelAncho = fisicoAncho > 0 ? fisicoAncho : _Gdi.caps(dc, _horzRes);
        final papelAlto = fisicoAlto > 0 ? fisicoAlto : _Gdi.caps(dc, _vertRes);

        for (var c = 0; c < copias; c++) {
          for (var i = 0; i < paginas; i++) {
            final pagina = _pdfium.loadPage(doc, i);
            if (pagina == nullptr) {
              throw ErrorImpresion('La página ${i + 1} del PDF no se pudo abrir.');
            }
            try {
              if (_Gdi.startPage(dc) <= 0) {
                throw ErrorImpresion('El spooler rechazó la página ${i + 1} en «$impresora».');
              }
              final caja = encaja(
                paginaAncho: _pdfium.pageWidth(pagina) / 72 * dpiX,
                paginaAlto: _pdfium.pageHeight(pagina) / 72 * dpiY,
                papelAncho: papelAncho.toDouble(),
                papelAlto: papelAlto.toDouble(),
              );
              final dibujada = _pdfium.renderPage(
                dc,
                pagina,
                caja.x - margenX,
                caja.y - margenY,
                caja.ancho,
                caja.alto,
                caja.girada ? 1 : 0,
                _fpdfAnnot | _fpdfPrinting,
              );
              if (dibujada == 0) {
                throw ErrorImpresion('PDFium no pudo dibujar la página ${i + 1} en «$impresora».');
              }
              if (_Gdi.endPage(dc) <= 0) {
                throw ErrorImpresion('El spooler no cerró la página ${i + 1} en «$impresora».');
              }
            } finally {
              _pdfium.closePage(pagina);
            }
          }
        }
        terminado = _Gdi.endDoc(dc) > 0;
        if (!terminado) {
          throw ErrorImpresion('El spooler no cerró el documento en «$impresora».');
        }
      } finally {
        if (!terminado) _Gdi.abortDoc(dc);
      }
    } finally {
      calloc
        ..free(titulo)
        ..free(info);
    }
  }

  /// Le pone al DEVMODE de la cola el papel de la página. Devuelve qué hizo,
  /// para el registro: cuando una etiqueta sale encogida, lo primero que hay
  /// que saber es con qué papel se abrió el trabajo.
  String _eligePapel(String impresora, _Devmode dm, double ancho, double alto) {
    // Décimas de milímetro: la unidad de los papeles en Windows.
    final w = (ancho / 72 * 254).round();
    final h = (alto / 72 * 254).round();
    final papeles = _Papeles.de(impresora, dm.puntero);
    final elegido = papelQueCoincide(papeles, w, h);
    if (elegido != null) {
      dm.ponPapel(elegido.id);
      dm.ponOrientacion(elegido.girado ? _landscape : _portrait);
    } else {
      dm.ponPapelAMedida(w, h);
    }
    dm.valida(impresora);
    final medida = '${(w / 10).toStringAsFixed(1)} × ${(h / 10).toStringAsFixed(1)} mm';
    return elegido == null
        ? 'página de $medida; el driver no tiene ese papel, se pidió a medida'
        : 'página de $medida en el papel «${elegido.nombre}»'
            '${elegido.girado ? ' (apaisado)' : ''}';
  }
}

/// Dónde y de qué tamaño se dibuja una página sobre el papel, en píxeles del
/// dispositivo.
class Encaje {
  const Encaje(this.x, this.y, this.ancho, this.alto, this.girada);
  final int x;
  final int y;
  final int ancho;
  final int alto;

  /// La página va girada 90°: es apaisada y el papel no (o al revés).
  final bool girada;
}

/// La página sobre el papel: a su tamaño si cabe, y si no, encogida hasta
/// caber, siempre centrada. Una página que es casi el papel (una etiqueta
/// sobre su propio rollo) se ajusta a él: así no queda un borde de un píxel.
///
/// Si página y papel están orientados al revés —una etiqueta apaisada en un
/// rollo que avanza a lo largo— se gira la página en vez de encogerla a un
/// tercio.
Encaje encaja({
  required double paginaAncho,
  required double paginaAlto,
  required double papelAncho,
  required double papelAlto,
}) {
  var pw = paginaAncho;
  var ph = paginaAlto;
  final girada = pw != ph && papelAncho != papelAlto && (pw > ph) != (papelAncho > papelAlto);
  if (girada) (pw, ph) = (ph, pw);
  final llena = pw > papelAncho * 0.95 || ph > papelAlto * 0.95;
  final escala = llena ? math.min(papelAncho / pw, papelAlto / ph) : 1.0;
  final ancho = (pw * escala).round();
  final alto = (ph * escala).round();
  return Encaje(
    ((papelAncho - ancho) / 2).round(),
    ((papelAlto - alto) / 2).round(),
    ancho,
    alto,
    girada,
  );
}

/// Un papel que declara el driver: id, nombre y medidas en décimas de mm.
class PapelDriver {
  const PapelDriver(this.id, this.nombre, this.ancho, this.alto, {this.girado = false});
  final int id;
  final String nombre;
  final int ancho;
  final int alto;

  /// Coincide con la página girada: hay que abrirlo apaisado.
  final bool girado;
}

/// El papel del driver que mide como la página (±3 mm por lado), derecho
/// antes que girado. Null si ninguno.
PapelDriver? papelQueCoincide(List<PapelDriver> papeles, int ancho, int alto) {
  const tolerancia = 30;
  bool cerca(int a, int b) => (a - b).abs() <= tolerancia;
  for (final p in papeles) {
    if (cerca(p.ancho, ancho) && cerca(p.alto, alto)) return p;
  }
  for (final p in papeles) {
    if (cerca(p.ancho, alto) && cerca(p.alto, ancho)) {
      return PapelDriver(p.id, p.nombre, p.ancho, p.alto, girado: true);
    }
  }
  return null;
}

// ───────────────────────────── Windows ─────────────────────────────

const _horzRes = 8;
const _vertRes = 10;
const _logPixelsX = 88;
const _logPixelsY = 90;
const _physicalWidth = 110;
const _physicalHeight = 111;
const _physicalOffsetX = 112;
const _physicalOffsetY = 113;

const _fpdfAnnot = 0x01;
const _fpdfPrinting = 0x800;

const _portrait = 1;
const _landscape = 2;

/// `DOCINFOW`
final class _DocInfoW extends Struct {
  @Int32()
  external int cbSize;
  external Pointer<Utf16> lpszDocName;
  external Pointer<Utf16> lpszOutput;
  external Pointer<Utf16> lpszDatatype;
  @Uint32()
  external int fwType;
}

/// `FS_SIZEF` de PDFium: ancho y alto en puntos.
final class _FsSizeF extends Struct {
  @Float()
  external double width;
  @Float()
  external double height;
}

class _Gdi {
  _Gdi._();

  static final DynamicLibrary _gdi = DynamicLibrary.open('gdi32.dll');

  static final _createDC = _gdi.lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint8>),
      int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint8>)>('CreateDCW');
  static final deleteDC =
      _gdi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
  static final startDoc = _gdi.lookupFunction<Int32 Function(IntPtr, Pointer<_DocInfoW>),
      int Function(int, Pointer<_DocInfoW>)>('StartDocW');
  static final endDoc =
      _gdi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('EndDoc');
  static final abortDoc =
      _gdi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('AbortDoc');
  static final startPage =
      _gdi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('StartPage');
  static final endPage =
      _gdi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('EndPage');
  static final caps = _gdi.lookupFunction<Int32 Function(IntPtr, Int32),
      int Function(int, int)>('GetDeviceCaps');

  /// El contexto de dispositivo de la cola, con el DEVMODE dado.
  static int createDC(String impresora, Pointer<Uint8> devmode) {
    final nombre = impresora.toNativeUtf16();
    try {
      return _createDC(nullptr, nombre, nullptr, devmode);
    } finally {
      calloc.free(nombre);
    }
  }
}

class _Spool {
  _Spool._();

  static final DynamicLibrary _dll = DynamicLibrary.open('winspool.drv');

  static final openPrinter = _dll.lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>),
      int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>)>('OpenPrinterW');
  static final closePrinter =
      _dll.lookupFunction<Int32 Function(IntPtr), int Function(int)>('ClosePrinter');
  static final documentProperties = _dll.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Uint8>, Pointer<Uint8>, Uint32),
      int Function(int, int, Pointer<Utf16>, Pointer<Uint8>, Pointer<Uint8>,
          int)>('DocumentPropertiesW');
  static final deviceCapabilities = _dll.lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint16, Pointer<Uint8>, Pointer<Uint8>),
      int Function(Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint8>,
          Pointer<Uint8>)>('DeviceCapabilitiesW');
}

/// El `DEVMODEW` de la cola: la configuración con que se abre el trabajo.
///
/// Se maneja como bytes con los desplazamientos del SDK en vez de declarar la
/// estructura: lleva uniones y una cola de bytes privados del driver
/// (`dmDriverExtra`) que hay que conservar enteros.
class _Devmode {
  _Devmode._(this.puntero, this._bytes);

  final Pointer<Uint8> puntero;
  final int _bytes;

  static const _dmFields = 72;
  static const _dmOrientation = 76;
  static const _dmPaperSize = 78;
  static const _dmPaperLength = 80;
  static const _dmPaperWidth = 82;

  static const _orientation = 0x1;
  static const _paperSize = 0x2;
  static const _paperLength = 0x4;
  static const _paperWidth = 0x8;

  static const _dmOutBuffer = 2;
  static const _dmInBuffer = 8;
  static const _paperUser = 256;

  /// La configuración por defecto de la cola, o null si no se pudo abrir.
  static _Devmode? porDefecto(String impresora) {
    return _conImpresora(impresora, (h, nombre) {
      final bytes = _Spool.documentProperties(0, h, nombre, nullptr, nullptr, 0);
      if (bytes <= 0) return null;
      final p = calloc<Uint8>(bytes);
      if (_Spool.documentProperties(0, h, nombre, p, nullptr, _dmOutBuffer) < 0) {
        calloc.free(p);
        return null;
      }
      return _Devmode._(p, bytes);
    });
  }

  void ponPapel(int id) {
    _i16(_dmPaperSize, id);
    _campos(_paperSize);
  }

  void ponOrientacion(int o) {
    _i16(_dmOrientation, o);
    _campos(_orientation);
  }

  void ponPapelAMedida(int ancho, int alto) {
    _i16(_dmPaperSize, _paperUser);
    _i16(_dmPaperWidth, ancho);
    _i16(_dmPaperLength, alto);
    _i16(_dmOrientation, _portrait);
    _campos(_paperSize | _paperWidth | _paperLength | _orientation);
  }

  /// Le pasa los cambios al driver para que los acepte o los corrija: lo que
  /// no entienda lo deja como lo tenía, en vez de que el trabajo salga con un
  /// papel imposible.
  void valida(String impresora) {
    _conImpresora(impresora, (h, nombre) {
      final copia = calloc<Uint8>(_bytes);
      try {
        copia.asTypedList(_bytes).setAll(0, puntero.asTypedList(_bytes));
        if (_Spool.documentProperties(
                0, h, nombre, puntero, copia, _dmInBuffer | _dmOutBuffer) <
            0) {
          // El driver no lo tomó: se vuelve a lo que había.
          puntero.asTypedList(_bytes).setAll(0, copia.asTypedList(_bytes));
        }
      } finally {
        calloc.free(copia);
      }
      return null;
    });
  }

  void libera() => calloc.free(puntero);

  void _i16(int desplazamiento, int valor) =>
      (puntero + desplazamiento).cast<Int16>().value = valor;

  void _campos(int bits) {
    final p = (puntero + _dmFields).cast<Uint32>();
    p.value = p.value | bits;
  }

  static T? _conImpresora<T>(String impresora, T? Function(int, Pointer<Utf16>) f) {
    final nombre = impresora.toNativeUtf16();
    final asa = calloc<IntPtr>();
    try {
      if (_Spool.openPrinter(nombre, asa, nullptr) == 0) return null;
      try {
        return f(asa.value, nombre);
      } finally {
        _Spool.closePrinter(asa.value);
      }
    } finally {
      calloc
        ..free(nombre)
        ..free(asa);
    }
  }
}

/// Los papeles que declara el driver, con su id, su nombre y su medida.
class _Papeles {
  _Papeles._();

  static const _dcPapers = 2;
  static const _dcPaperSize = 3;
  static const _dcPaperNames = 16;

  static List<PapelDriver> de(String impresora, Pointer<Uint8> devmode) {
    final nombre = impresora.toNativeUtf16();
    try {
      final n = _Spool.deviceCapabilities(nombre, nullptr, _dcPapers, nullptr, devmode);
      if (n <= 0) return const [];
      final ids = calloc<Uint16>(n);
      final medidas = calloc<Int32>(n * 2);
      final nombres = calloc<Uint16>(n * 64);
      try {
        _Spool.deviceCapabilities(nombre, nullptr, _dcPapers, ids.cast(), devmode);
        _Spool.deviceCapabilities(nombre, nullptr, _dcPaperSize, medidas.cast(), devmode);
        final hayNombres = _Spool.deviceCapabilities(
                nombre, nullptr, _dcPaperNames, nombres.cast(), devmode) >
            0;
        return [
          for (var i = 0; i < n; i++)
            PapelDriver(
              ids[i],
              hayNombres ? _nombre(nombres, i) : '#${ids[i]}',
              medidas[i * 2],
              medidas[i * 2 + 1],
            ),
        ];
      } finally {
        calloc
          ..free(ids)
          ..free(medidas)
          ..free(nombres);
      }
    } finally {
      calloc.free(nombre);
    }
  }

  /// Cada nombre son 64 caracteres UTF-16, terminado en cero si es más corto.
  static String _nombre(Pointer<Uint16> nombres, int i) {
    final codigos = <int>[];
    for (var c = 0; c < 64; c++) {
      final u = nombres[i * 64 + c];
      if (u == 0) break;
      codigos.add(u);
    }
    return String.fromCharCodes(codigos);
  }
}

/// Lo poco de PDFium que hace falta para imprimir.
class _Pdfium {
  _Pdfium(DynamicLibrary dll)
      : _init = dll.lookupFunction<Void Function(), void Function()>('FPDF_InitLibrary'),
        loadMemDocument = dll.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Int32, Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Void>, int, Pointer<Utf8>)>('FPDF_LoadMemDocument'),
        lastError =
            dll.lookupFunction<Uint32 Function(), int Function()>('FPDF_GetLastError'),
        pageCount = dll.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('FPDF_GetPageCount'),
        pageSizeByIndex = dll.lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Pointer<_FsSizeF>),
            int Function(Pointer<Void>, int, Pointer<_FsSizeF>)>('FPDF_GetPageSizeByIndexF'),
        loadPage = dll.lookupFunction<Pointer<Void> Function(Pointer<Void>, Int32),
            Pointer<Void> Function(Pointer<Void>, int)>('FPDF_LoadPage'),
        pageWidth = dll.lookupFunction<Float Function(Pointer<Void>),
            double Function(Pointer<Void>)>('FPDF_GetPageWidthF'),
        pageHeight = dll.lookupFunction<Float Function(Pointer<Void>),
            double Function(Pointer<Void>)>('FPDF_GetPageHeightF'),
        renderPage = dll.lookupFunction<
            Int32 Function(IntPtr, Pointer<Void>, Int32, Int32, Int32, Int32, Int32, Int32),
            int Function(int, Pointer<Void>, int, int, int, int, int, int)>('FPDF_RenderPage'),
        closePage = dll.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('FPDF_ClosePage'),
        closeDocument = dll.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('FPDF_CloseDocument');

  final void Function() _init;
  final Pointer<Void> Function(Pointer<Void>, int, Pointer<Utf8>) loadMemDocument;
  final int Function() lastError;
  final int Function(Pointer<Void>) pageCount;
  final int Function(Pointer<Void>, int, Pointer<_FsSizeF>) pageSizeByIndex;
  final Pointer<Void> Function(Pointer<Void>, int) loadPage;
  final double Function(Pointer<Void>) pageWidth;
  final double Function(Pointer<Void>) pageHeight;
  final int Function(int, Pointer<Void>, int, int, int, int, int, int) renderPage;
  final void Function(Pointer<Void>) closePage;
  final void Function(Pointer<Void>) closeDocument;

  bool _iniciada = false;

  /// PDFium se inicia una vez por proceso.
  void inicia() {
    if (_iniciada) return;
    _init();
    _iniciada = true;
  }
}
