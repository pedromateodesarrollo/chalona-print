using System.Collections.Generic;

namespace PrintServer
{
    enum EstadoServicio { NoInstalado, Detenido, Arrancando, EnMarcha, Deteniendo }

    enum Tono { Neutro, Bien, Aviso, Mal }

    enum AccionArranque { Ninguna, Instalar, Actualizar, Iniciar }

    /// <summary>
    /// Todo lo que la ventana sabe en un momento dado, y lo que concluye de ello.
    ///
    /// Las conclusiones —qué decir arriba, qué botón ofrecer en «Arranque con
    /// Windows»— están aquí y no en la ventana para poder probarlas sin
    /// Windows: son las que deciden si alguien se va creyendo que la
    /// computadora imprimirá mañana.
    /// </summary>
    sealed class Situacion
    {
        public ConfigAgente Config;
        public EstadoServicio Servicio = EstadoServicio.NoInstalado;
        public string VersionInstalada;
        public string VersionPropia = "";
        public List<string> ServiciosViejos = new List<string>();

        /// <summary>Null si el panel del agente no contesta.</summary>
        public EstadoAgente Agente;

        /// <summary>Lo último del registro en disco, para cuando el agente no contesta.</summary>
        public string[] RegistroEnDisco = new string[0];

        public bool Conectada => (Agente != null && Agente.Configurado) || (Config != null && Config.Configurado);

        public string Hub => Agente != null && Agente.Hub.Length > 0 ? Agente.Hub : Config?.Hub ?? "";

        public string Nombre => Agente != null && Agente.Nombre.Length > 0 ? Agente.Nombre : Config?.Nombre ?? "";

        public (string texto, Tono tono) Cabecera()
        {
            if (Agente != null)
            {
                if (!Agente.Configurado) return ("Sin conectar", Tono.Neutro);
                return Agente.Conectado ? ("Conectado", Tono.Bien) : ("Sin conexión con el hub", Tono.Mal);
            }
            if (!Conectada) return ("Sin conectar", Tono.Neutro);
            if (Servicio == EstadoServicio.EnMarcha || Servicio == EstadoServicio.Arrancando)
                return ("Arrancando…", Tono.Aviso);
            return ("Detenido: no imprime", Tono.Mal);
        }

        public (string texto, AccionArranque accion, bool desinstalar) Arranque()
        {
            var instalado = Servicio != EstadoServicio.NoInstalado;

            if (ServiciosViejos.Count > 0)
                return ($"Hay una versión anterior instalada ({string.Join(", ", ServiciosViejos)}). " +
                        "«Actualizar» la cambia por esta y conserva la conexión.",
                    AccionArranque.Actualizar, instalado);

            // Un agente que contesta pero no lo arrancó el servicio: una 0.2 en
            // primer plano o como tarea programada. Imprime hoy; mañana, quién sabe.
            if (Agente != null && !Agente.EsServicio)
                return ($"El agente corre fuera del servicio (versión {Agente.Version}): no es seguro que " +
                        "arranque con Windows. «Actualizar» lo deja como servicio.",
                    Conectada ? AccionArranque.Actualizar : AccionArranque.Ninguna, instalado);

            if (!instalado)
                return Conectada
                    ? ("No arranca con Windows: falta instalarlo como servicio.", AccionArranque.Instalar, false)
                    : ("Al conectar se instala como servicio de Windows y arranca solo, sin que nadie inicie sesión.",
                        AccionArranque.Ninguna, false);

            if (VersionInstalada != null)
            {
                var cmp = Versiones.Compara(VersionInstalada, VersionPropia);
                if (cmp < 0)
                    return ($"Instalada la versión {VersionInstalada}; esta es la {VersionPropia}. " +
                            "«Actualizar» la cambia sin perder la conexión.",
                        AccionArranque.Actualizar, true);
                if (cmp > 0)
                    return ($"Instalada la versión {VersionInstalada}, más nueva que esta ({VersionPropia}). " +
                            "Abre print-server desde el menú Inicio.",
                        AccionArranque.Ninguna, true);
            }

            switch (Servicio)
            {
                case EstadoServicio.EnMarcha:
                    return Conectada
                        ? ("Instalado y en marcha: arranca con Windows, sin que nadie inicie sesión.", AccionArranque.Ninguna, true)
                        : ("Instalado. Esperando que se conecte a un hub.", AccionArranque.Ninguna, true);
                case EstadoServicio.Arrancando:
                    return ("Arrancando el servicio…", AccionArranque.Ninguna, true);
                case EstadoServicio.Deteniendo:
                    return ("Deteniendo el servicio…", AccionArranque.Ninguna, true);
                default:
                    return ("Instalado, pero el servicio está detenido: esta computadora no imprime.",
                        AccionArranque.Iniciar, true);
            }
        }

        /// <summary>De la más vieja a la más nueva.</summary>
        public IList<string> Registro() =>
            Agente != null && Agente.Registro.Count > 0 ? (IList<string>)Agente.Registro : RegistroEnDisco;
    }
}
