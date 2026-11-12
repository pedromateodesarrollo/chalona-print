using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace PrintServer.Agente
{
    /// <summary>
    /// Driver del spooler de Windows (<c>winspool.drv</c>).
    ///
    /// La impresión RAW —ZPL, EPL, ESC/POS— va directa al spooler: es justo lo que
    /// no sobrevive a pasar por un intermediario que «ayuda» reformateando. El PDF
    /// va por el driver de la impresora con PDFium (<see cref="PdfPorDriver"/>),
    /// que viene con el agente. Las imágenes, por un ayudante externo opcional
    /// (SumatraPDF). Sin PDFium ni ayudante esta máquina reporta que solo admite
    /// <c>raw</c> y <c>texto</c>, y el hub rechaza el trabajo antes de encolarlo.
    /// </summary>
    sealed class DriverWindows : IDriver
    {
        readonly PdfPorDriver _porDriver;
        readonly AyudantePdf _ayudante;
        readonly List<string> _formatos;

        public DriverWindows()
        {
            _porDriver = PdfPorDriver.Detecta();
            _ayudante = AyudantePdf.Detecta();
            _formatos = new List<string> { "raw", "texto" };
            if (_porDriver != null || _ayudante != null) _formatos.Add("pdf");
            if (_ayudante != null) _formatos.Add("imagen");
        }

        public string Nombre
        {
            get
            {
                var partes = new List<string> { "windows" };
                if (_porDriver != null) partes.Add("pdfium");
                if (_ayudante != null) partes.Add(_ayudante.Estilo);
                return string.Join("+", partes);
            }
        }

        public (double ancho, double alto)? Papel(string impresora) => _porDriver?.PapelActual(impresora);

        public List<ImpresoraLocal> Inventario()
        {
            var predeterminada = Winspool.Predeterminada();
            return Winspool.Enumera().Select(i => new ImpresoraLocal
            {
                Sistema = i.Nombre,
                Nombre = i.Nombre,
                Estado = Estado(i),
                Detalle = Detalle(i.Estado),
                Cola = i.Trabajos,
                Predeterminada = i.Nombre == predeterminada,
                Formatos = _formatos,
                Modelo = i.Driver,
                Conexion = Conexion(i.Puerto),
                Serie = i.Puerto,
            }).ToList();
        }

        public void Imprime(TrabajoLocal t)
        {
            var documento = t.Nombre.Length == 0 ? "print-server" : t.Nombre;
            if (t.Formato == "raw" || t.Formato == "texto")
            {
                // Copias como documentos separados: el spooler no repite un trabajo
                // RAW por su cuenta, porque no sabe dónde acaba una etiqueta.
                for (var c = 0; c < Math.Max(1, t.Copias); c++)
                    Winspool.ImprimeCrudo(t.Impresora, documento, t.Contenido);
                return;
            }
            if (t.Formato == "pdf" && _porDriver != null)
            {
                _porDriver.Imprime(t.Impresora, documento, t.Contenido, Math.Max(1, t.Copias));
                return;
            }
            if (_ayudante == null)
            {
                throw new ErrorImpresion(
                    $"Esta computadora no puede imprimir {t.Formato}: Windows no renderiza PDF ni imágenes " +
                    "por sí solo. Instala SumatraPDF (o define PRINT_AGENTE_AYUDANTE_PDF con la ruta a un " +
                    "ayudante) y reinicia el agente.");
            }
            _ayudante.Imprime(t);
        }

        /// <summary>
        /// El nombre del puerto basta: <c>USB001</c> es un cable, <c>IP_…</c> o
        /// <c>WSD-…</c> la red, y <c>nul:</c> o <c>FILE:</c> no son una impresora
        /// que nadie vaya a reconocer en un pasillo.
        /// </summary>
        internal static string Conexion(string puerto)
        {
            var p = (puerto ?? "").ToUpperInvariant();
            if (p.StartsWith("USB")) return "usb";
            if (p.StartsWith("IP_") || p.StartsWith("WSD") || (p.Contains(":") && p.Contains("."))) return "red";
            if (p.StartsWith("LPT") || p.StartsWith("COM")) return "puerto";
            if (p.StartsWith("FILE") || p.StartsWith("NUL") || p.Contains("PORTPROMPT")) return "archivo";
            return "otro";
        }

        internal static string Estado(ImpresoraWin i)
        {
            const uint paused = 0x1, error = 0x2, paperJam = 0x8, paperOut = 0x10;
            const uint offline = 0x80, busy = 0x200, printing = 0x400;
            const uint notAvailable = 0x1000, doorOpen = 0x400000, noToner = 0x40000;
            var s = i.Estado;
            if ((s & (paperOut | paperJam)) != 0) return EstadoImpresora.SinPapel;
            if ((s & (error | offline | notAvailable | doorOpen | noToner)) != 0) return EstadoImpresora.Error;
            if ((s & paused) != 0) return EstadoImpresora.Pausada;
            if ((s & (busy | printing)) != 0 || i.Trabajos > 0) return EstadoImpresora.Ocupada;
            if (s == 0) return EstadoImpresora.Lista;
            return EstadoImpresora.Desconocida;
        }

        static readonly (uint bit, string texto)[] Nombres =
        {
            (0x1, "en pausa"),
            (0x2, "con error"),
            (0x8, "papel atascado"),
            (0x10, "sin papel"),
            (0x20, "esperando alimentación manual"),
            (0x40, "problema con el papel"),
            (0x80, "apagada o desconectada"),
            (0x800, "bandeja de salida llena"),
            (0x1000, "no disponible"),
            (0x20000, "poco tóner"),
            (0x40000, "sin tóner"),
            (0x100000, "necesita atención de una persona"),
            (0x400000, "tapa abierta"),
        };

        /// <summary>Los bits de estado en algo accionable: «0x10» no dice que hay que echar papel.</summary>
        internal static string Detalle(uint estado) =>
            string.Join(", ", Nombres.Where(n => (estado & n.bit) != 0).Select(n => n.texto));
    }

    /// <summary>Una impresora tal como la devuelve <c>EnumPrinters</c>.</summary>
    sealed class ImpresoraWin
    {
        public string Nombre = "";
        /// <summary>Bits <c>PRINTER_STATUS_*</c>.</summary>
        public uint Estado;
        public uint Trabajos;
        public string Driver = "";
        public string Puerto = "";
        public string Comentario = "";
    }

    /// <summary>Lo poco del spooler que hace falta: enumerar, la predeterminada y RAW.</summary>
    static class Winspool
    {
        const uint EnumLocal = 0x2;
        const uint EnumConnections = 0x4;

        /// <summary>
        /// Las impresoras locales y las conectadas por red. <c>EnumPrinters</c> se
        /// llama dos veces: la primera dice cuánta memoria hace falta.
        /// </summary>
        public static List<ImpresoraWin> Enumera()
        {
            var lista = new List<ImpresoraWin>();
            EnumPrintersW(EnumLocal | EnumConnections, null, 2, IntPtr.Zero, 0, out var necesario, out _);
            if (necesario == 0) return lista;
            var buffer = Marshal.AllocHGlobal((int)necesario);
            try
            {
                if (!EnumPrintersW(EnumLocal | EnumConnections, null, 2, buffer, necesario, out necesario, out var devueltas))
                    return lista;
                var tam = Marshal.SizeOf(typeof(PRINTER_INFO_2));
                for (var i = 0; i < devueltas; i++)
                {
                    var p = (PRINTER_INFO_2)Marshal.PtrToStructure(buffer + i * tam, typeof(PRINTER_INFO_2));
                    var nombre = Texto(p.pPrinterName);
                    if (nombre.Length == 0) continue;
                    lista.Add(new ImpresoraWin
                    {
                        Nombre = nombre,
                        Estado = p.Status,
                        Trabajos = p.cJobs,
                        Driver = Texto(p.pDriverName),
                        Puerto = Texto(p.pPortName),
                        Comentario = Texto(p.pComment),
                    });
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
            return lista;
        }

        public static string Predeterminada()
        {
            uint largo = 0;
            GetDefaultPrinterW(null, ref largo);
            if (largo == 0) return null;
            var sb = new System.Text.StringBuilder((int)largo);
            return GetDefaultPrinterW(sb, ref largo) ? sb.ToString() : null;
        }

        /// <summary>
        /// Manda los bytes al spooler sin que nadie los toque (datatype <c>RAW</c>):
        /// el camino de las etiquetas.
        /// </summary>
        public static void ImprimeCrudo(string impresora, string documento, byte[] datos)
        {
            if (!OpenPrinterW(impresora, out var h, IntPtr.Zero))
            {
                throw new ErrorImpresion(
                    $"Windows no pudo abrir la impresora «{impresora}». " +
                    "Comprueba que existe con ese nombre exacto y que el servicio tiene acceso.");
            }
            try
            {
                var doc = new DOC_INFO_1 { pDocName = documento, pOutputFile = null, pDatatype = "RAW" };
                if (StartDocPrinterW(h, 1, doc) == 0)
                    throw new ErrorImpresion($"El spooler rechazó el documento en «{impresora}»");
                try
                {
                    if (!StartPagePrinter(h)) throw new ErrorImpresion($"El spooler rechazó la página en «{impresora}»");
                    var buffer = Marshal.AllocHGlobal(Math.Max(1, datos.Length));
                    try
                    {
                        Marshal.Copy(datos, 0, buffer, datos.Length);
                        var ok = WritePrinter(h, buffer, (uint)datos.Length, out var escritos);
                        if (!ok || escritos != datos.Length)
                            throw new ErrorImpresion($"Se enviaron {escritos} de {datos.Length} bytes a «{impresora}»");
                    }
                    finally
                    {
                        Marshal.FreeHGlobal(buffer);
                    }
                    EndPagePrinter(h);
                }
                finally
                {
                    EndDocPrinter(h);
                }
            }
            finally
            {
                ClosePrinter(h);
            }
        }

        static string Texto(IntPtr p) => p == IntPtr.Zero ? "" : Marshal.PtrToStringUni(p) ?? "";

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        sealed class DOC_INFO_1
        {
            public string pDocName;
            public string pOutputFile;
            public string pDatatype;
        }

        /// <summary>El orden de los campos es el contrato con el sistema.</summary>
        [StructLayout(LayoutKind.Sequential)]
        struct PRINTER_INFO_2
        {
            public IntPtr pServerName;
            public IntPtr pPrinterName;
            public IntPtr pShareName;
            public IntPtr pPortName;
            public IntPtr pDriverName;
            public IntPtr pComment;
            public IntPtr pLocation;
            public IntPtr pDevMode;
            public IntPtr pSepFile;
            public IntPtr pPrintProcessor;
            public IntPtr pDatatype;
            public IntPtr pParameters;
            public IntPtr pSecurityDescriptor;
            public uint Attributes;
            public uint Priority;
            public uint DefaultPriority;
            public uint StartTime;
            public uint UntilTime;
            public uint Status;
            public uint cJobs;
            public uint AveragePPM;
        }

        [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool EnumPrintersW(uint flags, string nombre, uint nivel, IntPtr buffer, uint tam, out uint necesario, out uint devueltas);

        [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetDefaultPrinterW(System.Text.StringBuilder buffer, ref uint largo);

        [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool OpenPrinterW(string nombre, out IntPtr asa, IntPtr defecto);

        [DllImport("winspool.drv", SetLastError = true)]
        internal static extern bool ClosePrinter(IntPtr asa);

        [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern int StartDocPrinterW(IntPtr asa, uint nivel, [In] DOC_INFO_1 doc);

        [DllImport("winspool.drv", SetLastError = true)]
        static extern bool StartPagePrinter(IntPtr asa);

        [DllImport("winspool.drv", SetLastError = true)]
        static extern bool WritePrinter(IntPtr asa, IntPtr datos, uint largo, out uint escritos);

        [DllImport("winspool.drv", SetLastError = true)]
        static extern bool EndPagePrinter(IntPtr asa);

        [DllImport("winspool.drv", SetLastError = true)]
        static extern bool EndDocPrinter(IntPtr asa);
    }

    /// <summary>
    /// PDF e imágenes con un programa externo que ya esté en la máquina
    /// (SumatraPDF o PDFtoPrinter, o el de <c>PRINT_AGENTE_AYUDANTE_PDF</c>). El PDF
    /// va por PDFium; esto queda para las imágenes y para quien lo prefiera.
    /// </summary>
    sealed class AyudantePdf
    {
        public readonly string Ruta;
        /// <summary><c>sumatra</c> o <c>pdftoprinter</c>: cambian los argumentos.</summary>
        public readonly string Estilo;

        AyudantePdf(string ruta, string estilo)
        {
            Ruta = ruta;
            Estilo = estilo;
        }

        public static AyudantePdf Detecta()
        {
            var forzado = (Environment.GetEnvironmentVariable("PRINT_AGENTE_AYUDANTE_PDF") ?? "").Trim();
            if (forzado.Length > 0 && File.Exists(forzado))
                return new AyudantePdf(forzado, forzado.ToLowerInvariant().Contains("pdftoprinter") ? "pdftoprinter" : "sumatra");

            var programas = Environment.GetEnvironmentVariable("ProgramFiles") ?? @"C:\Program Files";
            var programasX86 = Environment.GetEnvironmentVariable("ProgramFiles(x86)") ?? @"C:\Program Files (x86)";
            var programasW6432 = Environment.GetEnvironmentVariable("ProgramW6432") ?? "";
            var local = Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? "";
            var candidatos = new List<(string ruta, string estilo)>
            {
                (Path.Combine(programas, @"SumatraPDF\SumatraPDF.exe"), "sumatra"),
                (Path.Combine(programasX86, @"SumatraPDF\SumatraPDF.exe"), "sumatra"),
            };
            // Un proceso de 32 bits ve «Program Files (x86)» como ProgramFiles.
            if (programasW6432.Length > 0) candidatos.Add((Path.Combine(programasW6432, @"SumatraPDF\SumatraPDF.exe"), "sumatra"));
            if (local.Length > 0) candidatos.Add((Path.Combine(local, @"SumatraPDF\SumatraPDF.exe"), "sumatra"));
            candidatos.Add((Path.Combine(programas, "PDFtoPrinter.exe"), "pdftoprinter"));

            foreach (var c in candidatos)
            {
                if (!File.Exists(c.ruta)) continue;
                Log.Info("windows", "ayudante de PDF: " + c.ruta);
                return new AyudantePdf(c.ruta, c.estilo);
            }
            return null;
        }

        public void Imprime(TrabajoLocal t)
        {
            var temporal = Path.Combine(Path.GetTempPath(), $"print-server-{t.Id}.{(t.Formato == "pdf" ? "pdf" : "img")}");
            File.WriteAllBytes(temporal, t.Contenido);
            try
            {
                for (var c = 0; c < Math.Max(1, t.Copias); c++)
                {
                    var args = Estilo == "pdftoprinter"
                        ? Argumentos.Une(new[] { temporal, t.Impresora })
                        : Argumentos.Une(new[] { "-print-to", t.Impresora, "-silent", "-exit-when-done", temporal });
                    var psi = new ProcessStartInfo(Ruta, args)
                    {
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardError = true,
                    };
                    using (var p = Process.Start(psi))
                    {
                        var error = p.StandardError.ReadToEndAsync();
                        if (!p.WaitForExit(120000))
                        {
                            try { p.Kill(); } catch (Win32Exception) { } catch (InvalidOperationException) { }
                            throw new ErrorImpresion("El ayudante de PDF no terminó en dos minutos.");
                        }
                        if (p.ExitCode != 0)
                            throw new ErrorImpresion($"El ayudante de PDF falló (código {p.ExitCode}): {error.Result}");
                    }
                }
            }
            finally
            {
                // El archivo lleva el documento del cliente; no se queda en el temporal.
                try { File.Delete(temporal); } catch (Exception) { }
            }
        }
    }
}
