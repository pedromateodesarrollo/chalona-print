import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'config.dart';
import 'log.dart';

/// El icono junto al reloj de Windows.
///
/// Corre en la sesión de quien inició sesión, no dentro del servicio: un
/// proceso de la sesión 0 —donde viven los servicios— no puede pintar iconos
/// en la barra de nadie. Por eso son dos procesos del mismo ejecutable.
///
/// El icono no sabe imprimir ni habla con el hub: le pregunta al panel local
/// (127.0.0.1) cómo va todo y abre esa misma página cuando le hacen clic. Así
/// la pantalla es una sola, y es la misma en Windows, Linux y macOS.
class Bandeja {
  Bandeja(this.config);

  final ConfigAgente config;
  final _terminado = Completer<void>();

  _BandejaWin? _win;

  String get _urlPanel => 'http://127.0.0.1:${config.puertoPanel}';

  /// Devuelve false si este sistema no tiene bandeja soportada; el que llama
  /// se limita a abrir el panel en el navegador.
  Future<bool> arranca() async {
    if (!Platform.isWindows) return false;
    try {
      final win = _BandejaWin(
        titulo: 'chalona-print',
        alAbrirPanel: () => _abre(_urlPanel),
        alSalir: () {
          if (!_terminado.isCompleted) _terminado.complete();
        },
      );
      win.crea();
      _win = win;
    } catch (e) {
      log.error('bandeja', 'no pude crear el icono: $e');
      return false;
    }

    // Bombea los mensajes de Windows desde un temporizador en vez de bloquear
    // el hilo en `GetMessage`: así el resto del programa —consultar el estado,
    // abrir el navegador— sigue funcionando.
    Timer.periodic(const Duration(milliseconds: 50), (t) {
      if (_terminado.isCompleted) {
        t.cancel();
        _win?.destruye();
        return;
      }
      _win?.bombea();
    });

    Timer.periodic(const Duration(seconds: 5), (t) async {
      if (_terminado.isCompleted) {
        t.cancel();
        return;
      }
      _win?.tooltip(await _estado());
    });

    return true;
  }

  Future<void> espera() => _terminado.future;

  Future<String> _estado() async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final pet = await c.getUrl(Uri.parse('$_urlPanel/estado.json'));
      final res = await pet.close();
      final d = jsonDecode(await utf8.decoder.bind(res).join());
      c.close();
      if (d is! Map) return 'chalona-print';
      final impresoras = (d['impresoras'] as List?)?.length ?? 0;
      return d['conectado'] == true
          ? 'chalona-print — conectado · $impresoras impresora(s)'
          : 'chalona-print — SIN CONEXIÓN con el hub';
    } catch (_) {
      return 'chalona-print — el servicio no responde';
    }
  }

  void _abre(String url) {
    final u = url.toNativeUtf16();
    final verbo = 'open'.toNativeUtf16();
    try {
      _BandejaWin.shellExecute(0, verbo, u, nullptr, nullptr, 1);
    } finally {
      calloc
        ..free(u)
        ..free(verbo);
    }
  }
}

// ---------------------------------------------------------------------------
// Todo lo que sigue es Win32 crudo. Se enlaza a mano por lo mismo que el
// spooler: menos dependencias que auditar en la máquina de un cliente.
// ---------------------------------------------------------------------------

const int _wmApp = 0x8000;
const int _wmIcono = _wmApp + 1;
const int _wmCommand = 0x0111;
const int _wmDestroy = 0x0002;
const int _wmLbuttonUp = 0x0202;
const int _wmRbuttonUp = 0x0205;

const int _nimAdd = 0x0;
const int _nimModify = 0x1;
const int _nimDelete = 0x2;
const int _nifMessage = 0x1;
const int _nifIcon = 0x2;
const int _nifTip = 0x4;

const int _idAbrir = 1;
const int _idSalir = 2;

final class _BandejaWin {
  _BandejaWin({
    required this.titulo,
    required this.alAbrirPanel,
    required this.alSalir,
  });

  final String titulo;
  final void Function() alAbrirPanel;
  final void Function() alSalir;

  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _shell32 = DynamicLibrary.open('shell32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final registerClass = _user32.lookupFunction<
      Uint16 Function(Pointer<_WndClassEx>),
      int Function(Pointer<_WndClassEx>)>('RegisterClassExW');
  static final createWindow = _user32.lookupFunction<
      IntPtr Function(Uint32, Pointer<Utf16>, Pointer<Utf16>, Uint32, Int32,
          Int32, Int32, Int32, IntPtr, IntPtr, IntPtr, Pointer<Void>),
      int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int, int,
          int, int, int, Pointer<Void>)>('CreateWindowExW');
  static final defWindowProc = _user32.lookupFunction<
      IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)>('DefWindowProcW');
  static final peekMessage = _user32.lookupFunction<
      Int32 Function(Pointer<_Msg>, IntPtr, Uint32, Uint32, Uint32),
      int Function(Pointer<_Msg>, int, int, int, int)>('PeekMessageW');
  static final translateMessage = _user32.lookupFunction<
      Int32 Function(Pointer<_Msg>), int Function(Pointer<_Msg>)>('TranslateMessage');
  static final dispatchMessage = _user32.lookupFunction<
      IntPtr Function(Pointer<_Msg>), int Function(Pointer<_Msg>)>('DispatchMessageW');
  static final destroyWindow = _user32.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('DestroyWindow');
  static final loadIcon = _user32.lookupFunction<
      IntPtr Function(IntPtr, IntPtr), int Function(int, int)>('LoadIconW');
  static final loadImage = _user32.lookupFunction<
      IntPtr Function(IntPtr, Pointer<Utf16>, Uint32, Int32, Int32, Uint32),
      int Function(int, Pointer<Utf16>, int, int, int, int)>('LoadImageW');
  static final createPopupMenu = _user32.lookupFunction<
      IntPtr Function(), int Function()>('CreatePopupMenu');
  static final appendMenu = _user32.lookupFunction<
      Int32 Function(IntPtr, Uint32, IntPtr, Pointer<Utf16>),
      int Function(int, int, int, Pointer<Utf16>)>('AppendMenuW');
  static final trackPopupMenu = _user32.lookupFunction<
      Int32 Function(IntPtr, Uint32, Int32, Int32, Int32, IntPtr, Pointer<Void>),
      int Function(int, int, int, int, int, int, Pointer<Void>)>('TrackPopupMenu');
  static final destroyMenu = _user32.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('DestroyMenu');
  static final getCursorPos = _user32.lookupFunction<
      Int32 Function(Pointer<_Punto>), int Function(Pointer<_Punto>)>('GetCursorPos');
  static final setForegroundWindow = _user32.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('SetForegroundWindow');
  static final shellNotifyIcon = _shell32.lookupFunction<
      Int32 Function(Uint32, Pointer<_NotifyIconData>),
      int Function(int, Pointer<_NotifyIconData>)>('Shell_NotifyIconW');
  static final shellExecute = _shell32.lookupFunction<
      IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
          Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
          Pointer<Utf16>, int)>('ShellExecuteW');
  static final getModuleHandle = _kernel32.lookupFunction<
      IntPtr Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('GetModuleHandleW');

  int _hwnd = 0;
  int _icono = 0;
  late final NativeCallable<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr)> _proc;
  final Pointer<_Msg> _msg = calloc<_Msg>();

  void crea() {
    // El callback se llama desde `DispatchMessage`, que corre en este mismo
    // hilo: por eso vale `isolateLocal`. Un callback llamado desde otro hilo
    // del sistema tumbaría el proceso.
    _proc = NativeCallable<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr)>
        .isolateLocal(_wndProc, exceptionalReturn: 0);

    final clase = 'ChalonaPrintBandeja'.toNativeUtf16();
    final wc = calloc<_WndClassEx>();
    wc.ref
      ..cbSize = sizeOf<_WndClassEx>()
      ..lpfnWndProc = _proc.nativeFunction
      ..hInstance = getModuleHandle(nullptr)
      ..lpszClassName = clase;
    registerClass(wc);

    _hwnd = createWindow(0, clase, clase, 0, 0, 0, 0, 0, 0, 0,
        getModuleHandle(nullptr), nullptr);
    calloc
      ..free(wc)
      ..free(clase);
    if (_hwnd == 0) throw StateError('CreateWindowEx falló');

    _icono = _cargaIcono();
    _notifica(_nimAdd, titulo);
  }

  /// Un `.ico` junto al ejecutable si está; si no, el icono genérico del
  /// sistema. Sin recurso incrustado: `dart compile exe` no sabe hacerlo, y
  /// entre no tener icono y tener uno prestado, mejor prestado.
  int _cargaIcono() {
    final carpeta = File(Platform.resolvedExecutable).parent.path;
    final ruta = '$carpeta\\chalona-print.ico';
    if (File(ruta).existsSync()) {
      final p = ruta.toNativeUtf16();
      try {
        const imageIcon = 1, lrLoadFromFile = 0x10, lrDefaultSize = 0x40;
        final h = loadImage(0, p, imageIcon, 0, 0, lrLoadFromFile | lrDefaultSize);
        if (h != 0) return h;
      } finally {
        calloc.free(p);
      }
    }
    const idiApplication = 32512;
    return loadIcon(0, idiApplication);
  }

  void tooltip(String texto) => _notifica(_nimModify, texto);

  void _notifica(int mensaje, String tip) {
    final datos = calloc<_NotifyIconData>();
    datos.ref
      ..cbSize = sizeOf<_NotifyIconData>()
      ..hWnd = _hwnd
      ..uID = 1
      ..uFlags = _nifMessage | _nifIcon | _nifTip
      ..uCallbackMessage = _wmIcono
      ..hIcon = _icono;
    final recortado = tip.length > 127 ? tip.substring(0, 127) : tip;
    for (var i = 0; i < recortado.length; i++) {
      datos.ref.szTip[i] = recortado.codeUnitAt(i);
    }
    datos.ref.szTip[recortado.length] = 0;
    shellNotifyIcon(mensaje, datos);
    calloc.free(datos);
  }

  void bombea() {
    const pmRemove = 0x0001;
    while (peekMessage(_msg, 0, 0, 0, pmRemove) != 0) {
      translateMessage(_msg);
      dispatchMessage(_msg);
    }
  }

  void destruye() {
    _notifica(_nimDelete, '');
    if (_hwnd != 0) destroyWindow(_hwnd);
    _proc.close();
    calloc.free(_msg);
  }

  int _wndProc(int hwnd, int mensaje, int wParam, int lParam) {
    if (mensaje == _wmIcono) {
      if (lParam == _wmLbuttonUp) {
        alAbrirPanel();
      } else if (lParam == _wmRbuttonUp) {
        _menu();
      }
      return 0;
    }
    if (mensaje == _wmCommand) {
      final id = wParam & 0xFFFF;
      if (id == _idAbrir) alAbrirPanel();
      if (id == _idSalir) alSalir();
      return 0;
    }
    if (mensaje == _wmDestroy) {
      alSalir();
      return 0;
    }
    return defWindowProc(hwnd, mensaje, wParam, lParam);
  }

  void _menu() {
    const mfString = 0x0;
    const tpmRightButton = 0x2, tpmReturnCmd = 0x100;
    final menu = createPopupMenu();
    final abrir = 'Abrir panel'.toNativeUtf16();
    final salir = 'Salir'.toNativeUtf16();
    final punto = calloc<_Punto>();
    try {
      appendMenu(menu, mfString, _idAbrir, abrir);
      appendMenu(menu, mfString, _idSalir, salir);
      getCursorPos(punto);
      // Sin esto el menú se queda pegado abierto cuando el usuario hace clic
      // fuera: es un requisito documentado de TrackPopupMenu.
      setForegroundWindow(_hwnd);
      final elegido = trackPopupMenu(menu, tpmRightButton | tpmReturnCmd,
          punto.ref.x, punto.ref.y, 0, _hwnd, nullptr);
      if (elegido == _idAbrir) alAbrirPanel();
      if (elegido == _idSalir) alSalir();
    } finally {
      destroyMenu(menu);
      calloc
        ..free(abrir)
        ..free(salir)
        ..free(punto);
    }
  }
}

final class _Punto extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class _Msg extends Struct {
  @IntPtr()
  external int hwnd;
  @Uint32()
  external int message;
  @IntPtr()
  external int wParam;
  @IntPtr()
  external int lParam;
  @Uint32()
  external int time;
  external _Punto pt;
}

final class _WndClassEx extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int style;
  external Pointer<NativeFunction<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr)>>
      lpfnWndProc;
  @Int32()
  external int cbClsExtra;
  @Int32()
  external int cbWndExtra;
  @IntPtr()
  external int hInstance;
  @IntPtr()
  external int hIcon;
  @IntPtr()
  external int hCursor;
  @IntPtr()
  external int hbrBackground;
  external Pointer<Utf16> lpszMenuName;
  external Pointer<Utf16> lpszClassName;
  @IntPtr()
  external int hIconSm;
}

/// `NOTIFYICONDATAW`. El `cbSize` que se manda es el tamaño que calcula Dart:
/// si esta estructura no cuadra con la del sistema, Windows rechaza el icono
/// en vez de corromper memoria.
final class _NotifyIconData extends Struct {
  @Uint32()
  external int cbSize;
  @IntPtr()
  external int hWnd;
  @Uint32()
  external int uID;
  @Uint32()
  external int uFlags;
  @Uint32()
  external int uCallbackMessage;
  @IntPtr()
  external int hIcon;
  @Array<Uint16>(128)
  external Array<Uint16> szTip;
  @Uint32()
  external int dwState;
  @Uint32()
  external int dwStateMask;
  @Array<Uint16>(256)
  external Array<Uint16> szInfo;
  @Uint32()
  external int uVersion;
  @Array<Uint16>(64)
  external Array<Uint16> szInfoTitle;
  @Uint32()
  external int dwInfoFlags;
  @Array<Uint8>(16)
  external Array<Uint8> guidItem;
  @IntPtr()
  external int hBalloonIcon;
}
