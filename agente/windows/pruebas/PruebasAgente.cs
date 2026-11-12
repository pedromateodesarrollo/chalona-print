using System;
using System.IO;
using System.Linq;
using System.Text;
using PrintServer.Agente;

namespace PrintServer
{
    /// <summary>
    /// Las pruebas del agente de Dart (agente/test/agente_test.dart), contra el
    /// agente de C#: mismos casos, mismas respuestas. Lo que toca el spooler se
    /// prueba en Windows (pruebas/humo.ps1).
    /// </summary>
    static class PruebasAgente
    {
        static Action<string, object, object> Igual;
        static Action<string, bool> Cierto;

        public static void Todas(Action<string, object, object> igual, Action<string, bool> cierto)
        {
            Igual = igual;
            Cierto = cierto;
            Urls();
            PaginaDePrueba();
            Pdf();
            Hechos_();
            Papel();
            Mensajes();
            Windows();
        }

        static ImpresoraLocal Ficha(string modelo, string fabricante = "", string sistema = "cola") =>
            new ImpresoraLocal { Sistema = sistema, Nombre = sistema, Estado = "lista", Modelo = modelo, Fabricante = fabricante };

        static string Contenido(ImpresoraLocal i, string cola) =>
            Encoding.GetEncoding(28591).GetString(Prueba.Crudo(Prueba.Lenguaje(i, cola), i, cola));

        static void Urls()
        {
            Igual("ws local", "ws://localhost:3070/agente/ws", new ConfigLocal { Hub = "http://localhost:3070" }.UrlWs);
            Igual("https → wss", "wss://print.chalonasoft.com/agente/ws", new ConfigLocal { Hub = "https://print.chalonasoft.com" }.UrlWs);
            Igual("hub bajo prefijo", "wss://ejemplo.com/print/agente/ws", new ConfigLocal { Hub = "https://ejemplo.com/print" }.UrlWs);
            Igual("normaliza sin esquema", "https://print.chalonasoft.com", Alta.Normaliza(" print.chalonasoft.com/ "));
            Igual("normaliza con puerto y prefijo", "http://10.0.0.5:3070/print", Alta.Normaliza("http://10.0.0.5:3070/print/"));
            Igual("normaliza vacío", null, Alta.Normaliza("  "));
        }

        static void PaginaDePrueba()
        {
            Igual("ESim", "epl", Prueba.Lenguaje(Ficha("Honeywell PC42t (203 dpi) - ESim"), ""));
            Igual("ZSim", "zpl", Prueba.Lenguaje(Ficha("Honeywell PC42t (203 dpi) - ZSim"), ""));
            Igual("ZDesigner", "zpl", Prueba.Lenguaje(Ficha("ZDesigner GK420d"), ""));
            Igual("Generic", "texto", Prueba.Lenguaje(Ficha("Generic / Text Only"), ""));
            Igual("- DP", "epl", Prueba.Lenguaje(null, "Honeywell PC42t (203 dpi) - DP"));
            Igual("PC42E-T", "epl", Prueba.Lenguaje(null, "Honeywell PC42E-T (203 dpi) - DP"));
            Igual("PC43 renombrada", "epl", Prueba.Lenguaje(Ficha("Honeywell PC43d"), "etiquetas almacen"));
            Igual("PD43", "epl", Prueba.Lenguaje(Ficha("Honeywell PD43"), ""));
            Igual("PM43", "epl", Prueba.Lenguaje(Ficha("Honeywell PM43"), ""));
            Igual("Direct Protocol", "epl", Prueba.Lenguaje(null, "PC42t Direct Protocol"));
            Igual("ZSim manda", "zpl", Prueba.Lenguaje(null, "Honeywell PC42t (203 dpi) - ZSim"));
            Igual("dpi no es DP", "texto", Prueba.Lenguaje(null, "HP LaserJet M404 (600 - dpi)"));
            Igual("Canon", "texto", Prueba.Lenguaje(null, "Canon_MF450_Series"));
            Igual("Generic renombrada", "texto", Prueba.Lenguaje(Ficha("Generic / Text Only"), "Recepcion"));
            Igual("cola ESim", "epl", Prueba.Lenguaje(null, "PC42t-203-ESim"));
            Igual("Fingerprint", "dp", Prueba.Lenguaje(Ficha("Honeywell PC42t Fingerprint"), ""));
            Igual("modelo - DP", "epl", Prueba.Lenguaje(Ficha("Honeywell PC42t (203 dpi) - DP"), ""));
            Igual("Beeprt", "epl", Prueba.Lenguaje(Ficha("Beeprt BY-426-4"), ""));
            Igual("TSC", "epl", Prueba.Lenguaje(Ficha("TSC TTP-244"), ""));
            Igual("LaserJet", "texto", Prueba.Lenguaje(Ficha("HP LaserJet 1020"), ""));

            const string cola = "Honeywell PC42t (203 dpi) - DP";
            var s = Contenido(Ficha("", sistema: cola), cola);
            Cierto("DP sale EPL", s.StartsWith("N\n") && s.Contains("P1") && !s.Contains("\f"));
            var zpl = Contenido(Ficha("ZDesigner"), "x");
            Cierto("ZPL envuelto", zpl.StartsWith("^XA") && zpl.Contains("^XZ"));
            var dp = Contenido(Ficha("… Fingerprint"), "x");
            Cierto("DP envuelto", dp.StartsWith("PP ") && dp.Contains("PT \"PRINT-SERVER\"") && dp.EndsWith("PF\r\n"));
            var texto = Contenido(Ficha("Generic"), "x");
            Cierto("texto con avance", texto.Contains("print-server") && texto.EndsWith("\f"));
            var comillas = Contenido(Ficha("ESim", sistema: "la \"buena\""), "la \"buena\"");
            Cierto("comillas EPL", comillas.Split('\n').Count(l => l.StartsWith("A")) > 2 && !comillas.Contains("\"la \"buena\"\""));
            const string larga = "Honeywell PC42t (203 dpi) - ESim";
            var recorte = Contenido(Ficha("ESim", sistema: larga), larga);
            Cierto("recorte latin1", recorte.Contains("Honeywell PC42t (203 dpi) -...") && !recorte.Contains("…"));
            Cierto("nombre raro", Contenido(Ficha("ESim", sistema: "Etiquetas ✓ recepción"), "Etiquetas ✓ recepción").Contains("Etiquetas ? recepci"));

            Igual("protocolo del hub manda", "zpl", Prueba.Protocolo(Ficha("Generic"), "x", " ZPL "));
            Igual("sin PDF va a texto", "texto", Prueba.Protocolo(Ficha("Generic"), "x"));
            var conPdf = Ficha("Generic");
            conPdf.Formatos = new System.Collections.Generic.List<string> { "raw", "pdf" };
            Igual("con PDF va por driver", "driver", Prueba.Protocolo(conPdf, "x"));
            Igual("etiquetadora sigue en EPL", "epl", Prueba.Protocolo(Ficha("ESim"), "x", "otro"));
        }

        static void Pdf()
        {
            var pdf = Encoding.GetEncoding(28591).GetString(PdfPrueba.Arma(153, 289, "PC42t (✓)", "ESTACION-1", new DateTime(2026, 11, 12, 9, 5, 0)));
            Cierto("PDF cabecera", pdf.StartsWith("%PDF-1.4\n") && pdf.EndsWith("%%EOF\n"));
            Cierto("PDF del tamaño del papel", pdf.Contains("/MediaBox [0 0 153.00 289.00]"));
            Cierto("PDF alargado gira el texto", pdf.Contains("0 -1 1 0 0 289.00 cm"));
            Cierto("PDF escapa paréntesis y latin1", pdf.Contains("(PC42t \\(?\\))"));
            Cierto("PDF fecha", pdf.Contains("(12/11/2026 09:05)"));
            // La tabla xref apunta a cada objeto: un lector estricto la sigue.
            var xref = pdf.Substring(pdf.IndexOf("xref\n", StringComparison.Ordinal));
            var primero = int.Parse(xref.Split('\n')[3].Substring(0, 10));
            Cierto("xref apunta al objeto 1", pdf.Substring(primero).StartsWith("1 0 obj"));
        }

        static void Hechos_()
        {
            var dir = Path.Combine(Path.GetTempPath(), "print-server-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                var ruta = Path.Combine(dir, "agente.json");
                Hechos.Abre(ruta).Anota(42);
                Cierto("hechos recuerda", Hechos.Abre(ruta).Contiene(42));
                Cierto("hechos no inventa", !Hechos.Abre(ruta).Contiene(43));
                var ruta2 = Path.Combine(dir, "otra", "agente.json");
                Directory.CreateDirectory(Path.GetDirectoryName(ruta2));
                var h = Hechos.Abre(ruta2, 5);
                for (var i = 1; i <= 8; i++) h.Anota(i);
                Cierto("hechos con tope", h.Contiene(8) && !h.Contiene(1));
                Cierto("hechos con tope tras reabrir", Hechos.Abre(ruta2, 5).Contiene(8));
            }
            finally
            {
                Directory.Delete(dir, true);
            }

            // La configuración que dejó el agente de Dart se lee entera.
            var cfg = Path.Combine(Path.GetTempPath(), "print-server-" + Guid.NewGuid().ToString("N") + ".json");
            File.WriteAllText(cfg, "{\n  \"hub\": \"https://print.chalonasoft.com\",\n  \"credencial\": \"cag_4_x\",\n  \"agente\": 4,\n" +
                                   "  \"nombre\": \"DESKTOP\",\n  \"huella\": \"DESKTOP:9d83\",\n  \"driver\": \"auto\",\n  \"puerto_panel\": 7717,\n  \"salida_falsa\": \"\"\n}");
            try
            {
                var c = ConfigLocal.Carga(cfg);
                Cierto("config de Dart", c.Configurado && c.Agente == 4 && c.Huella == "DESKTOP:9d83" && c.PuertoPanel == 7717);
                c.Guarda(cfg);
                var d = ConfigLocal.Carga(cfg);
                Cierto("config ida y vuelta", d.Credencial == "cag_4_x" && d.Hub == c.Hub && d.Nombre == "DESKTOP");
            }
            finally
            {
                File.Delete(cfg);
            }
        }

        static void Papel()
        {
            var papeles = new System.Collections.Generic.List<PapelDriver>
            {
                new PapelDriver { Id = 1, Nombre = "Carta", Ancho = 2159, Alto = 2794 },
                new PapelDriver { Id = 300, Nombre = "30323 Shipping", Ancho = 540, Alto = 1020 },
            };
            Igual("papel derecho", "30323 Shipping", PapelDriver.QueCoincide(papeles, 545, 1015)?.Nombre);
            var girado = PapelDriver.QueCoincide(papeles, 1020, 540);
            Cierto("papel girado", girado != null && girado.Id == 300 && girado.Girado);
            Igual("sin papel igual", null, PapelDriver.QueCoincide(papeles, 600, 400));

            var e = Encaje.Calcula(100, 50, 400, 800);
            Cierto("pequeña sin escalar, girada y centrada", e.Girada && e.Ancho == 50 && e.Alto == 100 && e.X == 175 && e.Y == 350);
            var lleno = Encaje.Calcula(1000, 1000, 400, 800);
            Cierto("grande encoge", !lleno.Girada && lleno.Ancho == 400 && lleno.Alto == 400 && lleno.Y == 200);
        }

        static void Mensajes()
        {
            Igual("alta: argumento", "La llave de API empieza por «cpk_»; revisa lo que pegaste",
                Alta.Mensaje(new ArgumentException("La llave de API empieza por «cpk_»; revisa lo que pegaste")));
            Cierto("alta: red", Alta.Mensaje(new System.Net.WebException("x", System.Net.WebExceptionStatus.ConnectFailure)).StartsWith("No pude llegar al hub"));
            Cierto("alta: no es hub", Alta.Mensaje(new FormatException("x")).Contains("no es un hub"));
            var caida = Cliente.MensajeDeConexion(new System.Net.WebSockets.WebSocketException("Unable to connect",
                new System.Net.WebException("No connection could be made", System.Net.WebExceptionStatus.ConnectFailure)));
            Cierto("conexión: sin hub", caida.StartsWith("No pude llegar al hub") && caida.EndsWith("(No connection could be made)"));
            var rechazo = Cliente.MensajeDeConexion(new System.Net.WebSockets.WebSocketException("x",
                new System.Net.WebException("(401) Unauthorized", System.Net.WebExceptionStatus.ProtocolError)));
            Cierto("conexión: rechazado", rechazo.StartsWith("El hub no aceptó la conexión"));
        }

        static void Windows()
        {
            Igual("puerto USB", "usb", DriverWindows.Conexion("USB001"));
            Igual("puerto IP", "red", DriverWindows.Conexion("IP_192.168.1.40"));
            Igual("puerto WSD", "red", DriverWindows.Conexion("WSD-1234"));
            Igual("puerto COM", "puerto", DriverWindows.Conexion("COM3:"));
            Igual("puerto PDF", "archivo", DriverWindows.Conexion("PORTPROMPT:"));
            Igual("estado lista", "lista", DriverWindows.Estado(new ImpresoraWin()));
            Igual("estado sin papel", "sin_papel", DriverWindows.Estado(new ImpresoraWin { Estado = 0x10 | 0x80 }));
            Igual("estado apagada", "error", DriverWindows.Estado(new ImpresoraWin { Estado = 0x80 }));
            Igual("estado pausada", "pausada", DriverWindows.Estado(new ImpresoraWin { Estado = 0x1 }));
            Igual("estado con cola", "ocupada", DriverWindows.Estado(new ImpresoraWin { Trabajos = 2 }));
            Igual("detalle", "sin papel, apagada o desconectada", DriverWindows.Detalle(0x10 | 0x80));
        }
    }
}
