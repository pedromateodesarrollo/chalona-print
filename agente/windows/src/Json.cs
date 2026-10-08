using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace PrintServer
{
    /// <summary>
    /// Lector y escritor de JSON mínimo.
    ///
    /// .NET Framework no trae uno que sirva sin arrastrar DLL al lado del .exe,
    /// y el programa tiene que ser un solo archivo: lo que se descarga es lo
    /// que se ejecuta. Lo que se lee aquí es poco y conocido —la configuración
    /// del agente y el estado de su panel—, así que alcanza con esto.
    ///
    /// Objetos → <c>Dictionary&lt;string, object&gt;</c>, listas →
    /// <c>List&lt;object&gt;</c>, números → <c>long</c> o <c>double</c>.
    /// </summary>
    static class Json
    {
        public static object Lee(string texto)
        {
            var l = new Lector(texto ?? "");
            l.Espacios();
            var v = l.Valor();
            l.Espacios();
            if (!l.Fin) throw l.Error("sobra texto después del valor");
            return v;
        }

        public static IDictionary<string, object> LeeObjeto(string texto) =>
            Lee(texto) as IDictionary<string, object>
            ?? throw new FormatException("JSON: se esperaba un objeto");

        public static string Texto(IDictionary<string, object> d, string clave, string otro = "")
        {
            if (d == null || !d.TryGetValue(clave, out var v) || v == null) return otro;
            return v as string ?? Convert.ToString(v, CultureInfo.InvariantCulture);
        }

        public static long Numero(IDictionary<string, object> d, string clave, long otro = 0)
        {
            if (d == null || !d.TryGetValue(clave, out var v) || v == null) return otro;
            if (v is long l) return l;
            if (v is double x) return (long)x;
            return long.TryParse(v as string, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : otro;
        }

        public static bool Booleano(IDictionary<string, object> d, string clave) =>
            d != null && d.TryGetValue(clave, out var v) && v is bool b && b;

        public static List<object> Lista(IDictionary<string, object> d, string clave) =>
            d != null && d.TryGetValue(clave, out var v) && v is List<object> l ? l : new List<object>();

        public static string Escribe(object v)
        {
            var sb = new StringBuilder();
            Escribe(sb, v);
            return sb.ToString();
        }

        static void Escribe(StringBuilder sb, object v)
        {
            switch (v)
            {
                case null:
                    sb.Append("null");
                    break;
                case string s:
                    Cadena(sb, s);
                    break;
                case bool b:
                    sb.Append(b ? "true" : "false");
                    break;
                case int _:
                case long _:
                case double _:
                    sb.Append(Convert.ToString(v, CultureInfo.InvariantCulture));
                    break;
                case IDictionary<string, object> d:
                    sb.Append('{');
                    var primero = true;
                    foreach (var kv in d)
                    {
                        if (!primero) sb.Append(',');
                        primero = false;
                        Cadena(sb, kv.Key);
                        sb.Append(':');
                        Escribe(sb, kv.Value);
                    }
                    sb.Append('}');
                    break;
                case IEnumerable lista:
                    sb.Append('[');
                    var p = true;
                    foreach (var x in lista)
                    {
                        if (!p) sb.Append(',');
                        p = false;
                        Escribe(sb, x);
                    }
                    sb.Append(']');
                    break;
                default:
                    Cadena(sb, Convert.ToString(v, CultureInfo.InvariantCulture));
                    break;
            }
        }

        static void Cadena(StringBuilder sb, string s)
        {
            sb.Append('"');
            foreach (var c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }

        sealed class Lector
        {
            readonly string _t;
            int _i;

            public Lector(string t) { _t = t; }

            public bool Fin => _i >= _t.Length;

            public FormatException Error(string que) => new FormatException($"JSON: {que} (posición {_i})");

            public void Espacios()
            {
                while (_i < _t.Length && char.IsWhiteSpace(_t[_i])) _i++;
            }

            public object Valor()
            {
                if (Fin) throw Error("se acabó el texto");
                var c = _t[_i];
                switch (c)
                {
                    case '{': return Objeto();
                    case '[': return Lista();
                    case '"': return Cadena();
                    case 't': return Palabra("true", true);
                    case 'f': return Palabra("false", false);
                    case 'n': return Palabra("null", null);
                }
                if (c == '-' || char.IsDigit(c)) return Numero();
                throw Error($"no esperaba «{c}»");
            }

            object Palabra(string p, object valor)
            {
                if (string.CompareOrdinal(_t, _i, p, 0, p.Length) != 0) throw Error($"se esperaba {p}");
                _i += p.Length;
                return valor;
            }

            Dictionary<string, object> Objeto()
            {
                var d = new Dictionary<string, object>();
                _i++;
                Espacios();
                if (!Fin && _t[_i] == '}') { _i++; return d; }
                while (true)
                {
                    Espacios();
                    if (Fin || _t[_i] != '"') throw Error("se esperaba una clave");
                    var clave = Cadena();
                    Espacios();
                    if (Fin || _t[_i] != ':') throw Error("se esperaban dos puntos");
                    _i++;
                    Espacios();
                    d[clave] = Valor();
                    Espacios();
                    if (Fin) throw Error("objeto sin cerrar");
                    if (_t[_i] == ',') { _i++; continue; }
                    if (_t[_i] == '}') { _i++; return d; }
                    throw Error("se esperaba , o }");
                }
            }

            List<object> Lista()
            {
                var l = new List<object>();
                _i++;
                Espacios();
                if (!Fin && _t[_i] == ']') { _i++; return l; }
                while (true)
                {
                    Espacios();
                    l.Add(Valor());
                    Espacios();
                    if (Fin) throw Error("lista sin cerrar");
                    if (_t[_i] == ',') { _i++; continue; }
                    if (_t[_i] == ']') { _i++; return l; }
                    throw Error("se esperaba , o ]");
                }
            }

            string Cadena()
            {
                var sb = new StringBuilder();
                _i++;
                while (true)
                {
                    if (Fin) throw Error("cadena sin cerrar");
                    var c = _t[_i++];
                    if (c == '"') return sb.ToString();
                    if (c != '\\') { sb.Append(c); continue; }
                    if (Fin) throw Error("escape sin terminar");
                    var e = _t[_i++];
                    switch (e)
                    {
                        case '"': sb.Append('"'); break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'u':
                            if (_i + 4 > _t.Length) throw Error("\\u incompleto");
                            sb.Append((char)int.Parse(_t.Substring(_i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                            _i += 4;
                            break;
                        default: throw Error($"escape desconocido \\{e}");
                    }
                }
            }

            object Numero()
            {
                var inicio = _i;
                if (_t[_i] == '-') _i++;
                while (_i < _t.Length && "0123456789.eE+-".IndexOf(_t[_i]) >= 0) _i++;
                var s = _t.Substring(inicio, _i - inicio);
                if (s.IndexOfAny(new[] { '.', 'e', 'E' }) < 0
                    && long.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var l))
                    return l;
                if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d)) return d;
                throw Error($"número inválido «{s}»");
            }
        }
    }
}
