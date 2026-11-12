using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace PrintServer.Agente
{
    /// <summary>
    /// Arma la página de prueba que entiende cada impresora (la misma lógica que
    /// <c>agente/lib/src/prueba.dart</c>).
    ///
    /// Vive en el agente y no en el hub a propósito: ninguno de los dos sabe si
    /// la impresora de enfrente habla EPL, ZPL o texto. Mandar texto plano a una
    /// etiquetadora en modo ESim no imprime nada <b>y el trabajo queda en
    /// «hecho»</b>: falla en silencio.
    /// </summary>
    static class Prueba
    {
        /// <summary>
        /// Etiquetadoras que no dicen su emulación en el nombre de la cola: la
        /// familia del modelo (PC42/PC43/PD43/PM43, sin cerrar la palabra: existe la
        /// «PC42E-T»), el sufijo «- DP» del driver de Honeywell y otras marcas.
        /// Sale EPL, que es lo que responde la mayoría del parque instalado.
        /// </summary>
        static readonly Regex Etiquetadoras = new Regex(
            @"\bp[cdm]4[23]" +
            @"|-\s*dp(?![a-z])" +
            @"|direct protocol" +
            @"|intermec|datamax|sato|tsc|godex|argox|bixolon|citizen|beeprt",
            RegexOptions.CultureInvariant);

        static readonly Encoding Latin1 = Encoding.GetEncoding(28591);

        /// <summary>Qué lenguaje habla, deducido del modelo y del nombre de la cola.</summary>
        public static string Lenguaje(ImpresoraLocal i, string nombreCola)
        {
            var pistas = string.Join(" ", new[] { i?.Modelo ?? "", i?.Fabricante ?? "", i?.Sistema ?? "", nombreCola ?? "" })
                .ToLowerInvariant();
            if (pistas.Contains("zsim") || pistas.Contains("zpl") || pistas.Contains("zdesigner") || pistas.Contains("zebra"))
                return "zpl";
            // `Fingerprint` nombra el lenguaje del firmware: la única pista que dice
            // de verdad qué habla. El sufijo `- DP` es del driver y cae en EPL.
            if (pistas.Contains("fingerprint")) return "dp";
            if (pistas.Contains("esim") || pistas.Contains("epl") || pistas.Contains("eltron") || Etiquetadoras.IsMatch(pistas))
                return "epl";
            return "texto";
        }

        /// <summary>
        /// Los protocolos con que se le puede hablar a una impresora. <c>driver</c>
        /// es el ESTÁNDAR: PDF por el driver, lo mismo que la página de prueba de
        /// Windows; los demás son el lenguaje crudo de una etiquetadora.
        /// </summary>
        public static readonly HashSet<string> Protocolos = new HashSet<string> { "driver", "zpl", "epl", "dp", "texto" };

        /// <summary>
        /// Manda lo que diga el hub (<paramref name="delHub"/>). Sin eso, las
        /// etiquetadoras que se reconocen por el nombre siguen en su lenguaje y todo
        /// lo demás va por el driver, si esta máquina puede imprimir PDF.
        /// </summary>
        public static string Protocolo(ImpresoraLocal i, string nombreCola, string delHub = null)
        {
            var fijado = (delHub ?? "").Trim().ToLowerInvariant();
            if (Protocolos.Contains(fijado)) return fijado;
            var l = Lenguaje(i, nombreCola);
            if (l != "texto") return l;
            return i != null && i.Formatos.Contains("pdf") ? "driver" : "texto";
        }

        /// <summary>
        /// Imprime la página de prueba en el protocolo que toca y dice cuál fue. La
        /// usan el hub (formato <c>prueba</c>), el panel y la consola.
        /// </summary>
        public static string Imprime(IDriver d, ImpresoraLocal i, string impresora, string delHub = null, string equipo = "", long id = -1)
        {
            var p = Protocolo(i, impresora, delHub);
            if (p == "driver")
            {
                var papel = d.Papel(impresora) ?? (612.0, 792.0);
                d.Imprime(new TrabajoLocal
                {
                    Id = id,
                    Impresora = impresora,
                    Formato = "pdf",
                    Nombre = "Prueba de print-server",
                    Contenido = PdfPrueba.Arma(papel.ancho, papel.alto, i?.Nombre ?? impresora, equipo),
                });
                return p;
            }
            d.Imprime(new TrabajoLocal
            {
                Id = id,
                Impresora = impresora,
                Formato = "raw",
                Nombre = "Prueba de print-server",
                Contenido = Crudo(p, i, impresora),
            });
            return p;
        }

        /// <summary>La prueba en un lenguaje crudo, ya en bytes listos para el spooler.</summary>
        public static byte[] Crudo(string lenguaje, ImpresoraLocal i, string nombreCola)
        {
            var ahora = DateTime.Now;
            var fecha = ahora.ToString("dd'/'MM'/'yyyy  HH':'mm", CultureInfo.InvariantCulture);
            var nombre = AsciiLatin1(Recorta(i?.Nombre ?? nombreCola ?? "", 30));
            string texto;
            switch (lenguaje)
            {
                case "epl":
                    // Todo por encima del dot 300: hay etiquetadoras con desplazamientos
                    // de origen que recortan el final.
                    texto = "N\n" +
                            "A30,30,0,4,1,1,N,\"PRINT-SERVER\"\n" +
                            $"A30,110,0,3,1,1,N,\"{nombre.Replace('"', '\'')}\"\n" +
                            $"A30,170,0,2,1,1,N,\"{fecha}\"\n" +
                            "A30,220,0,2,1,1,N,\"prueba de impresion\"\n" +
                            "P1\n";
                    break;
                case "zpl":
                    texto = "^XA\n" +
                            "^FO30,30^A0N,45,45^FDPRINT-SERVER^FS\n" +
                            $"^FO30,100^A0N,30,30^FD{Regex.Replace(nombre, @"[\^~]", "-")}^FS\n" +
                            $"^FO30,150^A0N,28,28^FD{fecha}^FS\n" +
                            "^FO30,195^A0N,28,28^FDprueba de impresion^FS\n" +
                            "^XZ\n";
                    break;
                case "dp":
                    // Direct Protocol (Fingerprint): posición, fuente, texto y `PF`.
                    texto = "PP 30,30\r\n" +
                            "FT \"Swiss 721 BT\",24\r\n" +
                            "PT \"PRINT-SERVER\"\r\n" +
                            "PP 30,70\r\n" +
                            "FT \"Swiss 721 BT\",12\r\n" +
                            $"PT \"{nombre.Replace('"', '\'')}\"\r\n" +
                            "PP 30,100\r\n" +
                            $"PT \"{fecha}\"\r\n" +
                            "PP 30,130\r\n" +
                            "PT \"prueba de impresion\"\r\n" +
                            "PF\r\n";
                    break;
                default:
                    // El avance de página al final hace que la hoja salga en vez de
                    // quedarse esperando en el búfer.
                    texto = "print-server\r\n" + nombre + "\r\n" + fecha + "\r\nprueba de impresion\r\n\r\n\r\n\f";
                    break;
            }
            return Latin1.GetBytes(texto);
        }

        static string Recorta(string s, int max) => s.Length <= max ? s : s.Substring(0, max - 3) + "...";

        /// <summary>
        /// Lo que no cabe en latin-1 se cambia por «?»: la prueba de una impresora no
        /// puede fallar por cómo se llama su cola.
        /// </summary>
        internal static string AsciiLatin1(string s) => Regex.Replace(s, @"[^\x20-\xFF]", "?");
    }

    /// <summary>
    /// La página de prueba del camino del driver, como PDF escrito a mano (seis
    /// objetos, las dos Helvetica que trae todo lector: nada que incrustar). Sale
    /// del tamaño del papel de la cola; en una etiqueta alargada el texto corre a
    /// lo largo. Es la de <c>pdf_prueba.dart</c>.
    /// </summary>
    static class PdfPrueba
    {
        static readonly Encoding Latin1 = Encoding.GetEncoding(28591);

        public static byte[] Arma(double ancho, double alto, string impresora, string equipo = "", DateTime? cuando = null)
        {
            var hora = cuando ?? DateTime.Now;
            var girada = alto > ancho * 1.3;
            var w = girada ? alto : ancho;
            var h = girada ? ancho : alto;
            var margen = Math.Min(w, h) * 0.08;

            var lineas = new List<(string texto, bool negrita, double peso)>
            {
                ("print-server", true, 1.0),
                ("Página de prueba por el driver", false, 0.55),
                (impresora, true, 0.55),
            };
            if (!string.IsNullOrEmpty(equipo)) lineas.Add((equipo, false, 0.45));
            lineas.Add((hora.ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture), false, 0.45));
            lineas.Add(("Si se lee entera, esta impresora imprime PDF.", false, 0.45));

            var util = w - margen * 2;
            var pesoTotal = lineas.Sum(l => l.peso * 1.25);
            var b = (h - margen * 2) / pesoTotal;
            var titulo = Math.Min(b, util / (lineas[0].texto.Length * 0.6));
            var tamanos = lineas.Select(l => Math.Min(Math.Min(b * l.peso, titulo * l.peso), util / (Math.Max(1, l.texto.Length) * 0.6))).ToList();

            var cs = new StringBuilder();
            if (girada) cs.Append($"0 -1 1 0 0 {N(alto)} cm\n");
            cs.Append($"2 w {N(margen / 2)} {N(margen / 2)} {N(w - margen)} {N(h - margen)} re S\n");
            var y = h - margen;
            for (var i = 0; i < lineas.Count; i++)
            {
                var t = tamanos[i];
                y -= t;
                cs.Append($"BT /{(lineas[i].negrita ? "F1" : "F2")} {N(t)} Tf {N(margen)} {N(y)} Td ({Cadena(lineas[i].texto)}) Tj ET\n");
                y -= t * 0.35;
            }

            var contenido = Latin1.GetBytes(cs.ToString());
            var objetos = new[]
            {
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {N(ancho)} {N(alto)}] " +
                "/Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            };

            using (var out_ = new MemoryStream())
            {
                void Escribe(string s)
                {
                    var bytes = Latin1.GetBytes(s);
                    out_.Write(bytes, 0, bytes.Length);
                }
                var desplazamientos = new List<long>();
                Escribe("%PDF-1.4\n");
                for (var i = 0; i < objetos.Length; i++)
                {
                    desplazamientos.Add(out_.Length);
                    Escribe($"{i + 1} 0 obj\n{objetos[i]}\nendobj\n");
                }
                desplazamientos.Add(out_.Length);
                Escribe($"6 0 obj\n<< /Length {contenido.Length} >>\nstream\n");
                out_.Write(contenido, 0, contenido.Length);
                Escribe("endstream\nendobj\n");
                var xref = out_.Length;
                Escribe("xref\n0 7\n0000000000 65535 f \n");
                foreach (var d in desplazamientos) Escribe(d.ToString("D10", CultureInfo.InvariantCulture) + " 00000 n \n");
                Escribe($"trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
                return out_.ToArray();
            }
        }

        static string N(double v) => v.ToString("F2", CultureInfo.InvariantCulture);

        static string Cadena(string s) => Prueba.AsciiLatin1(s)
            .Replace("\\", "\\\\")
            .Replace("(", "\\(")
            .Replace(")", "\\)");
    }
}
