import 'dart:convert';
import 'dart:typed_data';

import 'driver.dart';
import 'pdf_prueba.dart';

/// Arma la página de prueba que entiende cada impresora.
///
/// Esto vive en el agente y no en el hub ni en el panel a propósito: ninguno
/// de los dos sabe si la impresora de enfrente habla EPL, ZPL o texto. Mandar
/// texto plano a una etiquetadora en modo ESim no imprime nada **y el trabajo
/// queda en «hecho»**, que es la peor combinación posible: falla en silencio.
class Prueba {
  Prueba._();

  /// Etiquetadoras que no dicen su emulación en el nombre de la cola.
  ///
  /// El driver de Honeywell solo nombra la emulación cuando la hay: `- ESim`
  /// o `- ZSim`. Cuando la impresora viene en su lenguaje nativo la cola se
  /// llama `- DP` (Direct Protocol), y entonces el nombre deja de tener la
  /// palabra que buscábamos: «Honeywell PC42t (203 dpi) - DP» caía a texto,
  /// que en una etiquetadora es exactamente el fallo silencioso que este
  /// archivo existe para evitar. Se completa con la familia del modelo, que
  /// sí está siempre: una PC42/PC43/PD43/PM43 es una etiquetadora se llame
  /// como se llame la cola.
  ///
  /// Sale EPL y no Direct Protocol a propósito, aunque la cola diga `- DP`.
  /// Ese sufijo es el del driver de Windows, no el del modo del firmware: el
  /// 17SEP2026 dos colas con ese mismo nombre estaban una en ESim y otra en
  /// Direct Protocol de verdad. Por nombre no se puede distinguir, así que se
  /// elige EPL, que es lo que responde la mayoría del parque instalado.
  static final _etiquetadoras = RegExp(
    // PC42, PC43, PD43, PM43 — sin cerrar la palabra: existe la «PC42E-T».
    r'\bp[cdm]4[23]'
    // El sufijo del driver. El `(?![a-z])` es para no comerse «(203 - dpi)».
    r'|-\s*dp(?![a-z])'
    r'|direct protocol'
    // Otras marcas de etiquetadora que tampoco declaran lenguaje en la cola.
    r'|intermec|datamax|sato|tsc|godex|argox|bixolon|citizen|beeprt',
  );

  /// Qué lenguaje habla, deducido del modelo y del nombre de la cola.
  ///
  /// Las pistas vienen del propio fabricante: Honeywell nombra sus emulaciones
  /// `ESim` (EPL) y `ZSim` (ZPL), y el driver de Zebra se llama `ZDesigner`.
  ///
  /// Lo que el nombre NO dice es en qué modo está el firmware. Dos colas
  /// llamadas igual —`Honeywell PC42t (203 dpi) - DP`— resultaron estar una en
  /// ESim y otra en Direct Protocol, así que el sufijo del driver es una pista
  /// débil: dice para qué se instaló la cola, no qué habla la impresora.
  ///
  /// Por eso, cuando se reconoce una etiquetadora pero no su lenguaje, la
  /// prueba sale en EPL y no en texto. Mandar texto a una etiquetadora no
  /// imprime NADA y el trabajo queda en «hecho»: quien probó se queda mirando
  /// una impresora muda sin un solo indicio de qué pasó. En EPL, si el modo no
  /// coincide, la impresora al menos parpadea y eso ya orienta.
  static String lenguaje(ImpresoraLocal? i, String nombreCola) {
    final pistas = [
      i?.modelo ?? '',
      i?.fabricante ?? '',
      i?.sistema ?? '',
      nombreCola,
    ].join(' ').toLowerCase();

    if (pistas.contains('zsim') ||
        pistas.contains('zpl') ||
        pistas.contains('zdesigner') ||
        pistas.contains('zebra')) {
      return 'zpl';
    }
    // `Fingerprint` nombra el lenguaje del firmware, no el driver instalado:
    // es la única pista del nombre que dice de verdad qué habla la impresora.
    // El sufijo `- DP` es del driver de Windows y cae más abajo, en EPL.
    if (pistas.contains('fingerprint')) return 'dp';
    if (pistas.contains('esim') ||
        pistas.contains('epl') ||
        pistas.contains('eltron') ||
        _etiquetadoras.hasMatch(pistas)) {
      return 'epl';
    }
    return 'texto';
  }

  /// Los protocolos con que se le puede hablar a una impresora.
  ///
  /// `driver` es el ESTÁNDAR: PDF por el driver de la impresora, lo mismo que
  /// la página de prueba de Windows. Sirve con cualquier impresora que tenga
  /// driver —una DYMO no entiende ZPL, ni EPL, ni texto— sin saber qué
  /// lenguaje habla. Los demás son el lenguaje crudo de una etiquetadora:
  /// más rápidos y exactos, pero solo para la que lo habla.
  static const protocolos = {'driver', 'zpl', 'epl', 'dp', 'texto'};

  /// Cómo se le habla a esta impresora.
  ///
  /// Manda lo que diga el hub (`delHub`): ahí queda fijado el protocolo de cada
  /// modelo la primera vez que se ve, y el de una cola concreta cuando se sale
  /// de su modelo (Pedro, 2026-10-10). Sin eso, las etiquetadoras que se
  /// reconocen por el nombre siguen en su lenguaje —es lo que ya trabaja— y
  /// todo lo demás va por el driver, si esta máquina puede imprimir PDF. El
  /// texto crudo queda solo para donde no se puede.
  static String protocolo(ImpresoraLocal? i, String nombreCola, {String? delHub}) {
    final fijado = delHub?.trim().toLowerCase() ?? '';
    if (protocolos.contains(fijado)) return fijado;
    final l = lenguaje(i, nombreCola);
    if (l != 'texto') return l;
    return (i?.formatos.contains('pdf') ?? false) ? 'driver' : 'texto';
  }

  /// Imprime la página de prueba en el protocolo que toca y dice cuál fue.
  ///
  /// Por el driver es un PDF del tamaño del papel que tiene puesta la cola, para
  /// que salga entera; si el driver no lo dice, carta. Lo usan el hub (formato
  /// `prueba`), el panel y la consola: las tres pruebas son la misma.
  static Future<String> imprime(
    Driver d,
    ImpresoraLocal? i,
    String impresora, {
    String? delHub,
    String equipo = '',
    int id = -1,
  }) async {
    final p = protocolo(i, impresora, delHub: delHub);
    if (p == 'driver') {
      final papel = await d.papel(impresora) ?? (612.0, 792.0);
      await d.imprime(
        TrabajoLocal(
          id: id,
          impresora: impresora,
          formato: 'pdf',
          nombre: 'Prueba de print-server',
          contenido: pdfDePrueba(
            ancho: papel.$1,
            alto: papel.$2,
            impresora: i?.nombre ?? impresora,
            equipo: equipo,
          ),
        ),
      );
      return p;
    }
    await d.imprime(
      TrabajoLocal(
        id: id,
        impresora: impresora,
        formato: 'raw',
        nombre: 'Prueba de print-server',
        contenido: crudo(p, i, impresora),
      ),
    );
    return p;
  }

  /// El contenido de la prueba en el lenguaje que se deduce del nombre.
  static Uint8List contenido(ImpresoraLocal? i, String nombreCola) =>
      crudo(lenguaje(i, nombreCola), i, nombreCola);

  /// La prueba en un lenguaje crudo, ya en bytes listos para el spooler.
  static Uint8List crudo(String lenguaje, ImpresoraLocal? i, String nombreCola) {
    final ahora = DateTime.now();
    final fecha =
        '${_dd(ahora.day)}/${_dd(ahora.month)}/${ahora.year}  '
        '${_dd(ahora.hour)}:${_dd(ahora.minute)}';
    final nombre = _latin1(_recorta(i?.nombre ?? nombreCola, 30));

    switch (lenguaje) {
      case 'epl':
        // Todo por encima del dot 300: hay etiquetadoras con desplazamientos
        // de origen que recortan el final, y una prueba que se sale de la
        // etiqueta deja la impresora en error justo cuando alguien está
        // comprobando que funciona.
        return Uint8List.fromList(
          latin1.encode(
            'N\n'
            'A30,30,0,4,1,1,N,"PRINT-SERVER"\n'
            'A30,110,0,3,1,1,N,"${_epl(nombre)}"\n'
            'A30,170,0,2,1,1,N,"$fecha"\n'
            'A30,220,0,2,1,1,N,"prueba de impresion"\n'
            'P1\n',
          ),
        );

      case 'zpl':
        return Uint8List.fromList(
          latin1.encode(
            '^XA\n'
            '^FO30,30^A0N,45,45^FDPRINT-SERVER^FS\n'
            '^FO30,100^A0N,30,30^FD${_zpl(nombre)}^FS\n'
            '^FO30,150^A0N,28,28^FD$fecha^FS\n'
            '^FO30,195^A0N,28,28^FDprueba de impresion^FS\n'
            '^XZ\n',
          ),
        );

      case 'dp':
        // Direct Protocol, que por debajo es Fingerprint: posición, fuente,
        // texto y `PF` para que salga la etiqueta. Comprobado 17SEP2026 en una
        // PC42t que venía de fábrica en este modo.
        return Uint8List.fromList(
          latin1.encode(
            'PP 30,30\r\n'
            'FT "Swiss 721 BT",24\r\n'
            'PT "PRINT-SERVER"\r\n'
            'PP 30,70\r\n'
            'FT "Swiss 721 BT",12\r\n'
            'PT "${_dp(nombre)}"\r\n'
            'PP 30,100\r\n'
            'PT "$fecha"\r\n'
            'PP 30,130\r\n'
            'PT "prueba de impresion"\r\n'
            'PF\r\n',
          ),
        );

      default:
        // Texto para impresoras de página. El avance de página al final es lo
        // que hace que la hoja salga en vez de quedarse esperando en el búfer.
        return Uint8List.fromList(
          latin1.encode(
            'print-server\r\n'
            '$nombre\r\n'
            '$fecha\r\n'
            'prueba de impresion\r\n'
            '\r\n\r\n\f',
          ),
        );
    }
  }

  static String _dd(int n) => n.toString().padLeft(2, '0');

  static String _recorta(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 3)}...';

  /// Todo el comando se codifica en latin1, y `encode` revienta con cualquier
  /// carácter que no quepa en esa tabla. Lo ponía el propio recorte —unos
  /// puntos suspensivos— y puede ponerlo el nombre de la cola, que lo escribe
  /// quien instaló la impresora. El trabajo moría al armarlo, sin llegar al
  /// spooler: la prueba de una impresora no puede fallar por cómo se llama.
  static String _latin1(String s) => s.replaceAll(RegExp(r'[^\x20-\xFF]'), '?');

  /// En EPL las comillas delimitan el dato; una en el nombre parte el comando.
  static String _epl(String s) => s.replaceAll('"', "'");

  /// En ZPL, `^` y `~` son prefijos de comando.
  static String _zpl(String s) => s.replaceAll(RegExp(r'[\^~]'), '-');

  /// En Direct Protocol el dato va entre comillas, como en EPL.
  static String _dp(String s) => s.replaceAll('"', "'");
}
