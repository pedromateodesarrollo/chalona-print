using System;
using System.Collections.Generic;
using System.Linq;

namespace PrintServer
{
    static class Pruebas
    {
        static int _bien, _mal;

        static int Main()
        {
            Json_();
            Config_();
            Estado_();
            Versiones_();
            Argumentos_();
            Arranque_();
            Cabecera_();
            Console.WriteLine($"\n{_bien} bien, {_mal} mal");
            return _mal == 0 ? 0 : 1;
        }

        static void Igual<T>(string que, T esperado, T real)
        {
            if (Equals(esperado, real)) { _bien++; return; }
            _mal++;
            Console.WriteLine($"MAL  {que}\n     esperaba: {esperado}\n     salió:    {real}");
        }

        static void Cierto(string que, bool v) => Igual(que, true, v);

        static void Json_()
        {
            var d = Json.LeeObjeto("{\"a\": \"Conexi\\u00f3n «x»\", \"n\": -3, \"x\": 1.5, \"b\": true, \"l\": [1, \"dos\", null], \"o\": {}}");
            Igual("cadena con \\u y comillas latinas", "Conexión «x»", Json.Texto(d, "a"));
            Igual("entero negativo", -3L, Json.Numero(d, "n"));
            Igual("decimal", 1.5, (double)d["x"]);
            Cierto("booleano", Json.Booleano(d, "b"));
            Igual("lista", 3, Json.Lista(d, "l").Count);
            Igual("falta → otro", "z", Json.Texto(d, "no-esta", "z"));

            var ida = new Dictionary<string, object> { ["llave"] = "cpk_\"raro\"\\\n", ["n"] = 7 };
            var vuelta = Json.LeeObjeto(Json.Escribe(ida));
            Igual("escribe y lee lo mismo", "cpk_\"raro\"\\\n", Json.Texto(vuelta, "llave"));
            Igual("número de ida y vuelta", 7L, Json.Numero(vuelta, "n"));

            foreach (var malo in new[] { "", "{", "{\"a\":}", "[1,]", "{\"a\":1} x", "nul" })
            {
                try { Json.Lee(malo); _mal++; Console.WriteLine($"MAL  aceptó JSON roto: {malo}"); }
                catch (FormatException) { _bien++; }
            }
        }

        static void Config_()
        {
            var c = ConfigAgente.Desde("{\"hub\":\"https://print.chalonasoft.com\",\"credencial\":\"cpa_secreta\",\"agente\":3,\"nombre\":\"Duralon-Recepcion\",\"puerto_panel\":7717}");
            Cierto("conectada con hub y credencial", c.Configurado);
            Igual("número de agente", 3L, c.Agente);
            Cierto("la credencial no se guarda, solo si existe", c.TieneCredencial);
            Igual("puerto", 7717, c.PuertoPanel);

            Cierto("sin credencial no está conectada", !ConfigAgente.Desde("{\"hub\":\"https://x\",\"credencial\":\"\"}").Configurado);
            Igual("puerto absurdo → el de siempre", 7717, ConfigAgente.Desde("{\"puerto_panel\":99999}").PuertoPanel);
            Cierto("protegida cuenta como conectada", new ConfigAgente { Protegido = true }.Configurado);
            Igual("archivo que no existe → null", null, ConfigAgente.Lee("/no/existe/agente.json"));
        }

        static void Estado_()
        {
            // Lo que contesta el panel de un agente 0.4 corriendo como servicio.
            var e = EstadoAgente.Desde(@"{
              ""configurado"": true, ""hub"": ""https://print.chalonasoft.com"", ""agente"": 3,
              ""nombre"": ""Duralon-Recepcion"", ""version"": ""0.4.0"", ""modo"": ""servicio"",
              ""driver"": ""windows+sumatra"", ""conectado"": true,
              ""conectado_desde"": ""2026-10-08T07:52:58.123456"", ""impresos"": 1, ""fallidos"": 0,
              ""ultimo_error"": """",
              ""impresoras"": [
                {""sistema"": ""ZDesigner QLn320 (ZPL)"", ""nombre"": ""ZDesigner QLn320 (ZPL)"", ""estado"": ""ocupada"", ""detalle"": """", ""predeterminada"": true},
                {""sistema"": ""Fax"", ""nombre"": ""Fax"", ""estado"": ""lista"", ""predeterminada"": false}
              ],
              ""log"": [""tercera"", ""segunda"", ""primera""]
            }");
            Cierto("es servicio", e.EsServicio);
            Igual("agente como en la foto", "3 · Duralon-Recepcion (servicio, driver windows+sumatra)", Textos.Agente(e));
            Igual("fecha local", "08/10/2026 07:52:58", Fechas.Escribe(e.ConectadoDesde.Value));
            Igual("trabajos, singular y plural", "1 impreso · 0 fallidos", Textos.Trabajos(e));
            Igual("impresoras", 2, e.Impresoras.Count);
            Cierto("predeterminada", e.Impresoras[0].Predeterminada);
            Igual("estado traducido", "Ocupada", Textos.EstadoImpresora(e.Impresoras[0].Estado));
            Igual("el registro se lee de arriba abajo", "primera,segunda,tercera", string.Join(",", e.Registro));

            // Una 0.3.0 no decía el modo: sale la versión.
            var vieja = EstadoAgente.Desde("{\"agente\":3,\"nombre\":\"X\",\"version\":\"0.3.0\",\"driver\":\"windows\"}");
            Cierto("sin modo no es servicio", !vieja.EsServicio);
            Igual("sin modo dice la versión", "3 · X (versión 0.3.0, driver windows)", Textos.Agente(vieja));

            Igual("fecha en UTC → local", DateTime.SpecifyKind(new DateTime(2026, 10, 8, 11, 52, 58), DateTimeKind.Utc).ToLocalTime(),
                Fechas.Lee("2026-10-08T11:52:58Z").Value);
            Igual("fecha vacía", null, Fechas.Lee(""));
        }

        static void Versiones_()
        {
            Cierto("0.10 es más que 0.4", Versiones.Compara("0.10.0", "0.4.0") > 0);
            Cierto("0.3.0 es menos que 0.4.0", Versiones.Compara("0.3.0", "0.4.0") < 0);
            Igual("lo de tras el + no cuenta", 0, Versiones.Compara("0.4.0+abc", "0.4.0"));
            Igual("0.4 = 0.4.0", 0, Versiones.Compara("0.4", "0.4.0"));
            Igual("corta la de cuatro números", "0.4.0", Versiones.Corta("0.4.0.0"));
            Igual("completa la de dos", "0.4.0", Versiones.Corta("0.4"));
            Igual("deja el cuarto si no es cero", "1.2.3.4", Versiones.Corta("1.2.3.4"));
        }

        static void Argumentos_()
        {
            // Como CommandLineToArgvW: lo que se une tiene que volver igual.
            foreach (var a in new[]
            {
                "simple", "con espacio", @"C:\Program Files\print-server\", @"termina\", "comilla \"dentro\"",
                @"barras\\""y comilla", "", "cpk_ab+/=", "Ana María", @"\\servidor\cola",
            })
                Igual($"cita «{a}»", a, Parte(Argumentos.Cita(a)).Single());

            var l = Argumentos.Une(new[] { "--instalar", "--nombre", "Caja 2", "--resultado", @"C:\Users\Ana María\AppData\Local\Temp\r.txt" });
            Igual("varios", "--instalar|--nombre|Caja 2|--resultado|" + @"C:\Users\Ana María\AppData\Local\Temp\r.txt", string.Join("|", Parte(l)));

            var x = Argumentos.Lee(new[] { "--INSTALAR", "--hub", "https://h", "--nombre=Caja 2", "--solo" });
            Igual("orden en minúsculas", "--instalar", x.Orden);
            Igual("--clave valor", "https://h", x.Opcion("hub"));
            Igual("--clave=valor", "Caja 2", x.Opcion("nombre"));
            Cierto("bandera sola", x.Tiene("solo"));
            Igual("lo que falta, vacío", "", x.Opcion("llave"));
        }

        /// <summary>Las reglas de CommandLineToArgvW, para comprobar la cita.</summary>
        static List<string> Parte(string linea)
        {
            var salida = new List<string>();
            var actual = new System.Text.StringBuilder();
            var dentro = false;
            var hay = false;
            for (var i = 0; i < linea.Length; i++)
            {
                var c = linea[i];
                if (c == '\\')
                {
                    var n = 0;
                    while (i < linea.Length && linea[i] == '\\') { n++; i++; }
                    if (i < linea.Length && linea[i] == '"')
                    {
                        actual.Append('\\', n / 2);
                        if (n % 2 == 1) actual.Append('"');
                        else { dentro = !dentro; }
                    }
                    else
                    {
                        actual.Append('\\', n);
                        i--;
                    }
                    hay = true;
                    continue;
                }
                if (c == '"') { dentro = !dentro; hay = true; continue; }
                if (!dentro && (c == ' ' || c == '\t'))
                {
                    if (hay) { salida.Add(actual.ToString()); actual.Clear(); hay = false; }
                    continue;
                }
                actual.Append(c);
                hay = true;
            }
            if (hay) salida.Add(actual.ToString());
            return salida;
        }

        static EstadoAgente Agente(bool servicio, bool conectado = true, string version = "0.4.0") => new EstadoAgente
        {
            Configurado = true, Conectado = conectado, Hub = "https://h", Agente = 3, Nombre = "X",
            Version = version, Modo = servicio ? "servicio" : "", Driver = "windows",
        };

        static void Arranque_()
        {
            var conectada = new ConfigAgente { Hub = "https://h", TieneCredencial = true };

            var s = new Situacion { VersionPropia = "0.4.0", Config = null, Servicio = EstadoServicio.NoInstalado };
            Igual("recién descargado: nada que hacer hasta conectar", AccionArranque.Ninguna, s.Arranque().accion);
            Cierto("…y lo explica", s.Arranque().texto.Contains("Al conectar"));

            s = new Situacion { VersionPropia = "0.4.0", Config = conectada, Servicio = EstadoServicio.NoInstalado };
            Igual("conectada sin servicio → Instalar", AccionArranque.Instalar, s.Arranque().accion);

            s = new Situacion { VersionPropia = "0.4.0", Config = conectada, Servicio = EstadoServicio.EnMarcha, VersionInstalada = "0.4.0", Agente = Agente(true) };
            Igual("todo bien → sin botón", AccionArranque.Ninguna, s.Arranque().accion);
            Cierto("…con Desinstalar", s.Arranque().desinstalar);
            Igual("…y el texto de la foto", "Instalado y en marcha: arranca con Windows, sin que nadie inicie sesión.", s.Arranque().texto);

            // La 0.3.0, con su servicio de nombre viejo y su agente sin «modo».
            s = new Situacion { VersionPropia = "0.4.0", Config = conectada, ServiciosViejos = new List<string> { "chalona-print-agente" }, Agente = Agente(false, version: "0.3.0") };
            Igual("versión anterior como servicio → Actualizar", AccionArranque.Actualizar, s.Arranque().accion);
            Cierto("…nombra lo que encontró", s.Arranque().texto.Contains("chalona-print-agente"));

            // Taller-Repuesto el 2026-10-08: la 0.2.2 en primer plano tras fallar la tarea.
            s = new Situacion { VersionPropia = "0.4.0", Config = conectada, Agente = Agente(false, version: "0.2.2") };
            Igual("agente fuera del servicio → Actualizar", AccionArranque.Actualizar, s.Arranque().accion);
            Cierto("…y avisa de que no es seguro que arranque", s.Arranque().texto.Contains("no es seguro"));

            s = new Situacion { VersionPropia = "0.4.1", Config = conectada, Servicio = EstadoServicio.EnMarcha, VersionInstalada = "0.4.0", Agente = Agente(true) };
            Igual("instalada más vieja → Actualizar", AccionArranque.Actualizar, s.Arranque().accion);

            s = new Situacion { VersionPropia = "0.4.0", Config = conectada, Servicio = EstadoServicio.EnMarcha, VersionInstalada = "0.5.0", Agente = Agente(true) };
            Igual("instalada más nueva → no la pisa", AccionArranque.Ninguna, s.Arranque().accion);

            s = new Situacion { VersionPropia = "0.4.0", Config = conectada, Servicio = EstadoServicio.Detenido, VersionInstalada = "0.4.0" };
            Igual("servicio detenido → Iniciar", AccionArranque.Iniciar, s.Arranque().accion);
            Cierto("…y dice que no imprime", s.Arranque().texto.Contains("no imprime"));
        }

        static void Cabecera_()
        {
            var conectada = new ConfigAgente { Hub = "https://h", TieneCredencial = true };
            Igual("conectado", ("Conectado", Tono.Bien), new Situacion { Agente = Agente(true) }.Cabecera());
            Igual("sin hub", ("Sin conexión con el hub", Tono.Mal), new Situacion { Agente = Agente(true, conectado: false) }.Cabecera());
            Igual("nada", ("Sin conectar", Tono.Neutro), new Situacion().Cabecera());
            Igual("arrancando", ("Arrancando…", Tono.Aviso), new Situacion { Config = conectada, Servicio = EstadoServicio.EnMarcha }.Cabecera());
            Igual("detenido", ("Detenido: no imprime", Tono.Mal), new Situacion { Config = conectada, Servicio = EstadoServicio.Detenido }.Cabecera());
        }
    }
}
