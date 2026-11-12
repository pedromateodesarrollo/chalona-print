using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace PrintServer.Agente
{
    /// <summary>
    /// PDF por el driver de la impresora, sin programas externos (la misma lógica
    /// que <c>pdf_driver_windows.dart</c>).
    ///
    /// Es el camino ESTÁNDAR: lo que hace Windows con su página de prueba. El PDF
    /// se le da al driver ya dibujado —el motor es PDFium, el de Chrome, que viene
    /// dentro del paquete— y el driver lo traduce a lo que hable la impresora.
    ///
    /// <b>El papel lo pone la página.</b> Se busca, entre los papeles del driver, el
    /// que mide lo mismo que la página (±3 mm); si no hay, se pide a medida; y si
    /// tampoco lo acepta, la página se encoge para caber en el que haya.
    /// </summary>
    sealed class PdfPorDriver
    {
        /// <summary>PDFium no se puede usar desde dos hilos a la vez.</summary>
        static readonly object Cerrojo = new object();

        readonly Pdfium _pdfium;

        PdfPorDriver(Pdfium p) { _pdfium = p; }

        /// <summary>
        /// <c>pdfium.dll</c> donde diga <c>PRINT_AGENTE_PDFIUM</c>, junto al .exe (así
        /// lo deja la instalación) o, si no, la que lleva dentro el paquete sacada a
        /// una carpeta temporal. Tiene que ser de la arquitectura del proceso: una de
        /// otra no carga y se prueba la siguiente.
        /// </summary>
        public static PdfPorDriver Detecta()
        {
            var candidatas = new List<string>();
            var forzada = (Environment.GetEnvironmentVariable("PRINT_AGENTE_PDFIUM") ?? "").Trim();
            if (forzada.Length > 0) candidatas.Add(forzada);
            candidatas.Add(Path.Combine(Path.GetDirectoryName(Rutas.EsteEjecutable), "pdfium.dll"));
            foreach (var ruta in candidatas)
            {
                if (!File.Exists(ruta)) continue;
                var p = Carga(ruta);
                if (p != null) return p;
            }
            var extraida = ExtraeDelPaquete();
            return extraida == null ? null : Carga(extraida);
        }

        static PdfPorDriver Carga(string ruta)
        {
            try
            {
                var p = new PdfPorDriver(new Pdfium(ruta));
                Log.Info("windows", "PDF por el driver con " + ruta);
                return p;
            }
            catch (Exception e)
            {
                Log.Aviso("windows", $"no se pudo cargar {ruta}: {e.Message}");
                return null;
            }
        }

        static string ExtraeDelPaquete()
        {
            try
            {
                using (var r = Assembly.GetExecutingAssembly().GetManifestResourceStream("pdfium.dll"))
                {
                    if (r == null) return null;
                    var dir = Path.Combine(Path.GetTempPath(), $"print-server-pdfium-{Rutas.Version}-{Equipo.Arquitectura()}");
                    var ruta = Path.Combine(dir, "pdfium.dll");
                    if (File.Exists(ruta) && new FileInfo(ruta).Length == r.Length) return ruta;
                    Directory.CreateDirectory(dir);
                    var temporal = ruta + "." + Guid.NewGuid().ToString("N");
                    using (var f = File.Create(temporal)) r.CopyTo(f);
                    try
                    {
                        if (File.Exists(ruta)) File.Delete(ruta);
                        File.Move(temporal, ruta);
                    }
                    catch (IOException)
                    {
                        // Otro proceso la dejó a la vez; vale la suya.
                        try { File.Delete(temporal); } catch (Exception) { }
                    }
                    return ruta;
                }
            }
            catch (Exception e)
            {
                Log.Aviso("windows", "no pude sacar PDFium del paquete: " + e.Message);
                return null;
            }
        }

        /// <summary>
        /// El papel que tiene elegido la cola ahora, en puntos (1/72"). Es la medida
        /// de la página de prueba: que salga entera en lo que hay puesto.
        /// </summary>
        public (double ancho, double alto)? PapelActual(string impresora)
        {
            var dm = Devmode.PorDefecto(impresora);
            if (dm == null) return null;
            IntPtr dc;
            try
            {
                dc = Gdi.CreateDCW(null, impresora, null, dm.Puntero);
            }
            finally
            {
                dm.Libera();
            }
            if (dc == IntPtr.Zero) return null;
            try
            {
                var ancho = Gdi.GetDeviceCaps(dc, Gdi.PhysicalWidth);
                var alto = Gdi.GetDeviceCaps(dc, Gdi.PhysicalHeight);
                var dpiX = Gdi.GetDeviceCaps(dc, Gdi.LogPixelsX);
                var dpiY = Gdi.GetDeviceCaps(dc, Gdi.LogPixelsY);
                if (ancho <= 0 || alto <= 0 || dpiX <= 0 || dpiY <= 0) return null;
                return (ancho / (double)dpiX * 72, alto / (double)dpiY * 72);
            }
            finally
            {
                Gdi.DeleteDC(dc);
            }
        }

        /// <summary>Imprime el PDF entero en <paramref name="impresora"/>, <paramref name="copias"/> veces.</summary>
        public void Imprime(string impresora, string documento, byte[] pdf, int copias = 1)
        {
            lock (Cerrojo)
            {
                _pdfium.Inicia();
                var datos = Marshal.AllocHGlobal(Math.Max(1, pdf.Length));
                var doc = IntPtr.Zero;
                try
                {
                    Marshal.Copy(pdf, 0, datos, pdf.Length);
                    doc = _pdfium.LoadMemDocument(datos, pdf.Length, IntPtr.Zero);
                    if (doc == IntPtr.Zero)
                        throw new ErrorImpresion($"El PDF no se pudo abrir (PDFium dijo {_pdfium.GetLastError()}): está dañado o no es un PDF.");
                    var paginas = _pdfium.GetPageCount(doc);
                    if (paginas <= 0) throw new ErrorImpresion("El PDF no tiene páginas.");

                    _pdfium.GetPageSizeByIndexF(doc, 0, out var medida);
                    var dm = Devmode.PorDefecto(impresora);
                    if (dm == null)
                        throw new ErrorImpresion($"Windows no pudo abrir la impresora «{impresora}». Comprueba que existe con ese nombre exacto.");
                    try
                    {
                        var papel = EligePapel(impresora, dm, medida.Ancho, medida.Alto);
                        Log.Info("windows", $"«{impresora}»: {papel}");
                        var dc = Gdi.CreateDCW(null, impresora, null, dm.Puntero);
                        if (dc == IntPtr.Zero)
                            throw new ErrorImpresion($"El driver de «{impresora}» no abrió el dispositivo de impresión.");
                        try
                        {
                            ImprimeEn(dc, doc, paginas, documento, copias, impresora);
                        }
                        finally
                        {
                            Gdi.DeleteDC(dc);
                        }
                    }
                    finally
                    {
                        dm.Libera();
                    }
                }
                finally
                {
                    if (doc != IntPtr.Zero) _pdfium.CloseDocument(doc);
                    Marshal.FreeHGlobal(datos);
                }
            }
        }

        void ImprimeEn(IntPtr dc, IntPtr doc, int paginas, string documento, int copias, string impresora)
        {
            var info = new Gdi.DOCINFOW
            {
                cbSize = Marshal.SizeOf(typeof(Gdi.DOCINFOW)),
                lpszDocName = documento.Length == 0 ? "print-server" : documento,
            };
            if (Gdi.StartDocW(dc, ref info) <= 0)
                throw new ErrorImpresion($"El spooler rechazó el documento en «{impresora}».");
            var terminado = false;
            try
            {
                var fisicoAncho = Gdi.GetDeviceCaps(dc, Gdi.PhysicalWidth);
                var fisicoAlto = Gdi.GetDeviceCaps(dc, Gdi.PhysicalHeight);
                var margenX = Gdi.GetDeviceCaps(dc, Gdi.PhysicalOffsetX);
                var margenY = Gdi.GetDeviceCaps(dc, Gdi.PhysicalOffsetY);
                var dpiX = Gdi.GetDeviceCaps(dc, Gdi.LogPixelsX);
                var dpiY = Gdi.GetDeviceCaps(dc, Gdi.LogPixelsY);
                // Un driver que no da el físico (raro, pero los hay) se mide por lo imprimible.
                var papelAncho = fisicoAncho > 0 ? fisicoAncho : Gdi.GetDeviceCaps(dc, Gdi.HorzRes);
                var papelAlto = fisicoAlto > 0 ? fisicoAlto : Gdi.GetDeviceCaps(dc, Gdi.VertRes);

                for (var c = 0; c < copias; c++)
                {
                    for (var i = 0; i < paginas; i++)
                    {
                        var pagina = _pdfium.LoadPage(doc, i);
                        if (pagina == IntPtr.Zero) throw new ErrorImpresion($"La página {i + 1} del PDF no se pudo abrir.");
                        try
                        {
                            if (Gdi.StartPage(dc) <= 0)
                                throw new ErrorImpresion($"El spooler rechazó la página {i + 1} en «{impresora}».");
                            var caja = Encaje.Calcula(
                                _pdfium.GetPageWidthF(pagina) / 72 * dpiX,
                                _pdfium.GetPageHeightF(pagina) / 72 * dpiY,
                                papelAncho, papelAlto);
                            // FPDF_RenderPage no devuelve nada: un fallo de dibujo lo dice el spooler.
                            _pdfium.RenderPage(dc, pagina, caja.X - margenX, caja.Y - margenY, caja.Ancho, caja.Alto,
                                caja.Girada ? 1 : 0, Pdfium.Annot | Pdfium.Printing);
                            if (Gdi.EndPage(dc) <= 0)
                                throw new ErrorImpresion($"El spooler no cerró la página {i + 1} en «{impresora}».");
                        }
                        finally
                        {
                            _pdfium.ClosePage(pagina);
                        }
                    }
                }
                terminado = Gdi.EndDoc(dc) > 0;
                if (!terminado) throw new ErrorImpresion($"El spooler no cerró el documento en «{impresora}».");
            }
            finally
            {
                if (!terminado) Gdi.AbortDoc(dc);
            }
        }

        /// <summary>
        /// Le pone al DEVMODE de la cola el papel de la página. Devuelve qué hizo,
        /// para el registro: cuando una etiqueta sale encogida, lo primero que hay
        /// que saber es con qué papel se abrió el trabajo.
        /// </summary>
        static string EligePapel(string impresora, Devmode dm, double ancho, double alto)
        {
            // Décimas de milímetro: la unidad de los papeles en Windows.
            var w = (int)Math.Round(ancho / 72 * 254, MidpointRounding.AwayFromZero);
            var h = (int)Math.Round(alto / 72 * 254, MidpointRounding.AwayFromZero);
            var elegido = PapelDriver.QueCoincide(PapelDriver.De(impresora, dm.Puntero), w, h);
            if (elegido != null)
            {
                dm.PonPapel(elegido.Id);
                dm.PonOrientacion(elegido.Girado ? Devmode.Landscape : Devmode.Portrait);
            }
            else
            {
                dm.PonPapelAMedida(w, h);
            }
            dm.Valida(impresora);
            var medida = $"{(w / 10.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)} × " +
                         $"{(h / 10.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)} mm";
            return elegido == null
                ? $"página de {medida}; el driver no tiene ese papel, se pidió a medida"
                : $"página de {medida} en el papel «{elegido.Nombre}»{(elegido.Girado ? " (apaisado)" : "")}";
        }
    }

    /// <summary>Dónde y de qué tamaño se dibuja una página sobre el papel, en píxeles del dispositivo.</summary>
    sealed class Encaje
    {
        public int X, Y, Ancho, Alto;

        /// <summary>La página va girada 90°: es apaisada y el papel no (o al revés).</summary>
        public bool Girada;

        /// <summary>
        /// A su tamaño si cabe, y si no, encogida hasta caber, siempre centrada. Una
        /// página que es casi el papel se ajusta a él; si página y papel están
        /// orientados al revés, se gira en vez de encogerla a un tercio.
        /// </summary>
        public static Encaje Calcula(double paginaAncho, double paginaAlto, double papelAncho, double papelAlto)
        {
            var pw = paginaAncho;
            var ph = paginaAlto;
            var girada = pw != ph && papelAncho != papelAlto && (pw > ph) != (papelAncho > papelAlto);
            if (girada)
            {
                var t = pw;
                pw = ph;
                ph = t;
            }
            var llena = pw > papelAncho * 0.95 || ph > papelAlto * 0.95;
            var escala = llena ? Math.Min(papelAncho / pw, papelAlto / ph) : 1.0;
            var ancho = (int)Math.Round(pw * escala, MidpointRounding.AwayFromZero);
            var alto = (int)Math.Round(ph * escala, MidpointRounding.AwayFromZero);
            return new Encaje
            {
                X = (int)Math.Round((papelAncho - ancho) / 2, MidpointRounding.AwayFromZero),
                Y = (int)Math.Round((papelAlto - alto) / 2, MidpointRounding.AwayFromZero),
                Ancho = ancho,
                Alto = alto,
                Girada = girada,
            };
        }
    }

    /// <summary>Un papel que declara el driver: id, nombre y medidas en décimas de mm.</summary>
    sealed class PapelDriver
    {
        public int Id;
        public string Nombre = "";
        public int Ancho;
        public int Alto;

        /// <summary>Coincide con la página girada: hay que abrirlo apaisado.</summary>
        public bool Girado;

        /// <summary>El que mide como la página (±3 mm por lado), derecho antes que girado.</summary>
        public static PapelDriver QueCoincide(List<PapelDriver> papeles, int ancho, int alto)
        {
            const int tolerancia = 30;
            bool Cerca(int a, int b) => Math.Abs(a - b) <= tolerancia;
            foreach (var p in papeles)
                if (Cerca(p.Ancho, ancho) && Cerca(p.Alto, alto)) return p;
            foreach (var p in papeles)
                if (Cerca(p.Ancho, alto) && Cerca(p.Alto, ancho))
                    return new PapelDriver { Id = p.Id, Nombre = p.Nombre, Ancho = p.Ancho, Alto = p.Alto, Girado = true };
            return null;
        }

        const ushort DcPapers = 2;
        const ushort DcPaperSize = 3;
        const ushort DcPaperNames = 16;

        public static List<PapelDriver> De(string impresora, IntPtr devmode)
        {
            var lista = new List<PapelDriver>();
            var n = Gdi.DeviceCapabilitiesW(impresora, null, DcPapers, IntPtr.Zero, devmode);
            if (n <= 0) return lista;
            var ids = Marshal.AllocHGlobal(n * 2);
            var medidas = Marshal.AllocHGlobal(n * 8);
            var nombres = Marshal.AllocHGlobal(n * 64 * 2);
            try
            {
                Gdi.DeviceCapabilitiesW(impresora, null, DcPapers, ids, devmode);
                Gdi.DeviceCapabilitiesW(impresora, null, DcPaperSize, medidas, devmode);
                var hayNombres = Gdi.DeviceCapabilitiesW(impresora, null, DcPaperNames, nombres, devmode) > 0;
                for (var i = 0; i < n; i++)
                {
                    var id = (ushort)Marshal.ReadInt16(ids, i * 2);
                    var nombre = "#" + id;
                    if (hayNombres)
                    {
                        // Cada nombre son 64 caracteres UTF-16, terminado en cero si es más corto.
                        var chars = new char[64];
                        var largo = 0;
                        for (; largo < 64; largo++)
                        {
                            var u = (char)Marshal.ReadInt16(nombres, (i * 64 + largo) * 2);
                            if (u == 0) break;
                            chars[largo] = u;
                        }
                        nombre = new string(chars, 0, largo);
                    }
                    lista.Add(new PapelDriver
                    {
                        Id = id,
                        Nombre = nombre,
                        Ancho = Marshal.ReadInt32(medidas, i * 8),
                        Alto = Marshal.ReadInt32(medidas, i * 8 + 4),
                    });
                }
            }
            finally
            {
                Marshal.FreeHGlobal(ids);
                Marshal.FreeHGlobal(medidas);
                Marshal.FreeHGlobal(nombres);
            }
            return lista;
        }
    }

    /// <summary>
    /// El <c>DEVMODEW</c> de la cola. Se maneja como bytes con los desplazamientos
    /// del SDK en vez de declarar la estructura: lleva uniones y una cola de bytes
    /// privados del driver (<c>dmDriverExtra</c>) que hay que conservar enteros.
    /// Los desplazamientos son los mismos en 32 y en 64 bits.
    /// </summary>
    sealed class Devmode
    {
        public readonly IntPtr Puntero;
        readonly int _bytes;

        const int DmFields = 72;
        const int DmOrientation = 76;
        const int DmPaperSize = 78;
        const int DmPaperLength = 80;
        const int DmPaperWidth = 82;

        const uint Orientation = 0x1;
        const uint PaperSize = 0x2;
        const uint PaperLength = 0x4;
        const uint PaperWidth = 0x8;

        const int DmOutBuffer = 2;
        const int DmInBuffer = 8;
        const short PaperUser = 256;

        public const short Portrait = 1;
        public const short Landscape = 2;

        Devmode(IntPtr p, int bytes)
        {
            Puntero = p;
            _bytes = bytes;
        }

        /// <summary>La configuración por defecto de la cola, o null si no se pudo abrir.</summary>
        public static Devmode PorDefecto(string impresora)
        {
            if (!Winspool.OpenPrinterW(impresora, out var h, IntPtr.Zero)) return null;
            try
            {
                var bytes = Gdi.DocumentPropertiesW(IntPtr.Zero, h, impresora, IntPtr.Zero, IntPtr.Zero, 0);
                if (bytes <= 0) return null;
                var p = Marshal.AllocHGlobal(bytes);
                if (Gdi.DocumentPropertiesW(IntPtr.Zero, h, impresora, p, IntPtr.Zero, DmOutBuffer) < 0)
                {
                    Marshal.FreeHGlobal(p);
                    return null;
                }
                return new Devmode(p, bytes);
            }
            finally
            {
                Winspool.ClosePrinter(h);
            }
        }

        public void PonPapel(int id)
        {
            Marshal.WriteInt16(Puntero, DmPaperSize, (short)id);
            Campos(PaperSize);
        }

        public void PonOrientacion(short o)
        {
            Marshal.WriteInt16(Puntero, DmOrientation, o);
            Campos(Orientation);
        }

        public void PonPapelAMedida(int ancho, int alto)
        {
            Marshal.WriteInt16(Puntero, DmPaperSize, PaperUser);
            Marshal.WriteInt16(Puntero, DmPaperWidth, (short)ancho);
            Marshal.WriteInt16(Puntero, DmPaperLength, (short)alto);
            Marshal.WriteInt16(Puntero, DmOrientation, Portrait);
            Campos(PaperSize | PaperWidth | PaperLength | Orientation);
        }

        /// <summary>
        /// Le pasa los cambios al driver para que los acepte o los corrija: lo que
        /// no entienda lo deja como lo tenía, en vez de un papel imposible.
        /// </summary>
        public void Valida(string impresora)
        {
            if (!Winspool.OpenPrinterW(impresora, out var h, IntPtr.Zero)) return;
            var copia = Marshal.AllocHGlobal(_bytes);
            try
            {
                var tmp = new byte[_bytes];
                Marshal.Copy(Puntero, tmp, 0, _bytes);
                Marshal.Copy(tmp, 0, copia, _bytes);
                if (Gdi.DocumentPropertiesW(IntPtr.Zero, h, impresora, Puntero, copia, DmInBuffer | DmOutBuffer) < 0)
                {
                    // El driver no lo tomó: se vuelve a lo que había.
                    Marshal.Copy(tmp, 0, Puntero, _bytes);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(copia);
                Winspool.ClosePrinter(h);
            }
        }

        public void Libera() => Marshal.FreeHGlobal(Puntero);

        void Campos(uint bits)
        {
            var v = (uint)Marshal.ReadInt32(Puntero, DmFields);
            Marshal.WriteInt32(Puntero, DmFields, (int)(v | bits));
        }
    }

    static class Gdi
    {
        public const int HorzRes = 8;
        public const int VertRes = 10;
        public const int LogPixelsX = 88;
        public const int LogPixelsY = 90;
        public const int PhysicalWidth = 110;
        public const int PhysicalHeight = 111;
        public const int PhysicalOffsetX = 112;
        public const int PhysicalOffsetY = 113;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DOCINFOW
        {
            public int cbSize;
            public string lpszDocName;
            public string lpszOutput;
            public string lpszDatatype;
            public uint fwType;
        }

        [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateDCW(string driver, string dispositivo, string salida, IntPtr devmode);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteDC(IntPtr dc);

        [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int StartDocW(IntPtr dc, ref DOCINFOW info);

        [DllImport("gdi32.dll")]
        public static extern int EndDoc(IntPtr dc);

        [DllImport("gdi32.dll")]
        public static extern int AbortDoc(IntPtr dc);

        [DllImport("gdi32.dll")]
        public static extern int StartPage(IntPtr dc);

        [DllImport("gdi32.dll")]
        public static extern int EndPage(IntPtr dc);

        [DllImport("gdi32.dll")]
        public static extern int GetDeviceCaps(IntPtr dc, int indice);

        [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int DocumentPropertiesW(IntPtr ventana, IntPtr impresora, string nombre, IntPtr salida, IntPtr entrada, int modo);

        [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int DeviceCapabilitiesW(string dispositivo, string puerto, ushort capacidad, IntPtr salida, IntPtr devmode);
    }

    /// <summary>
    /// Lo poco de PDFium que hace falta para imprimir, enlazado a mano con
    /// <c>LoadLibrary</c>: así se carga la DLL exacta que se eligió (la de la
    /// arquitectura del proceso) y no otra que Windows encuentre por su cuenta.
    /// PDFium exporta en cdecl también en 32 bits (comprobado en el binario).
    /// </summary>
    sealed class Pdfium
    {
        public const int Annot = 0x01;
        public const int Printing = 0x800;

        [StructLayout(LayoutKind.Sequential)]
        public struct FS_SIZEF
        {
            public float Ancho;
            public float Alto;
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void FInit();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate IntPtr FLoadMem(IntPtr datos, int largo, IntPtr clave);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate uint FLastError();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int FPageCount(IntPtr doc);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int FPageSize(IntPtr doc, int indice, out FS_SIZEF medida);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate IntPtr FLoadPage(IntPtr doc, int indice);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate float FPageDim(IntPtr pagina);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void FRender(IntPtr dc, IntPtr pagina, int x, int y, int ancho, int alto, int giro, int banderas);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void FClose(IntPtr p);

        readonly FInit _init;
        public readonly FLoadMem LoadMemDocument;
        public readonly FLastError GetLastError;
        public readonly FPageCount GetPageCount;
        public readonly FPageSize GetPageSizeByIndexF;
        public readonly FLoadPage LoadPage;
        public readonly FPageDim GetPageWidthF;
        public readonly FPageDim GetPageHeightF;
        public readonly FRender RenderPage;
        public readonly FClose ClosePage;
        public readonly FClose CloseDocument;
        bool _iniciada;

        public Pdfium(string ruta)
        {
            var dll = LoadLibraryW(ruta);
            if (dll == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            T F<T>(string nombre) where T : class
            {
                var p = GetProcAddress(dll, nombre);
                if (p == IntPtr.Zero) throw new EntryPointNotFoundException(nombre);
                return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
            }
            _init = F<FInit>("FPDF_InitLibrary");
            LoadMemDocument = F<FLoadMem>("FPDF_LoadMemDocument");
            GetLastError = F<FLastError>("FPDF_GetLastError");
            GetPageCount = F<FPageCount>("FPDF_GetPageCount");
            GetPageSizeByIndexF = F<FPageSize>("FPDF_GetPageSizeByIndexF");
            LoadPage = F<FLoadPage>("FPDF_LoadPage");
            GetPageWidthF = F<FPageDim>("FPDF_GetPageWidthF");
            GetPageHeightF = F<FPageDim>("FPDF_GetPageHeightF");
            RenderPage = F<FRender>("FPDF_RenderPage");
            ClosePage = F<FClose>("FPDF_ClosePage");
            CloseDocument = F<FClose>("FPDF_CloseDocument");
        }

        /// <summary>PDFium se inicia una vez por proceso.</summary>
        public void Inicia()
        {
            if (_iniciada) return;
            _init();
            _iniciada = true;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr LoadLibraryW(string ruta);

        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true, ExactSpelling = true)]
        static extern IntPtr GetProcAddress(IntPtr modulo, string nombre);
    }
}
