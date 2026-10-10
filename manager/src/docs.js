// Fuente única de la documentación del API.
//
// De aquí sale la página de documentación del sitio Y el archivo `docs/api.md`
// del repositorio (`npm run docs`). Con dos fuentes, una de las dos miente a
// los tres meses.

export const intro = {
  titulo: 'API de print-server',
  texto:
    'Todo lo que hace el panel se puede hacer por API: no hay nada reservado a la ' +
    'interfaz. La base es la dirección de tu hub, y las respuestas son JSON.',
}

export const autenticacion = [
  {
    titulo: 'Llave de API',
    texto:
      'Para las aplicaciones. Va en la cabecera `authorization: Bearer cpk_...` ' +
      '(también se acepta `x-api-key`). No caduca; se revoca desde el panel o por API.',
    ejemplo: 'curl -H "authorization: Bearer cpk_ab12cd34_..." https://TU-HUB/v1/impresoras',
  },
  {
    titulo: 'Permisos de una llave',
    texto:
      '`trabajos:escribir` manda a imprimir · `trabajos:leer` consulta · ' +
      '`impresoras:leer` lista impresoras · `agentes:registrar` deja instalar agentes · ' +
      '`admin` abre todo el API, incluida la gestión de usuarios y de otras llaves.',
  },
  {
    titulo: 'Llaves acotadas a un dominio',
    texto:
      'Una llave puede quedar encerrada en un dominio. Entonces solo ve sus ' +
      'impresoras, solo imprime ahí y los agentes que instale nacen en ese ' +
      'dominio. Sin dominio, la llave alcanza toda la organización.',
  },
  {
    titulo: 'Sesión de persona',
    texto:
      'La del panel. `POST /v1/auth/login` devuelve un JWT que dura siete días y ' +
      'viaja en la misma cabecera. Quien olvidó su clave pide un enlace para poner ' +
      'otra (`POST /v1/auth/recuperar`), que llega por el correo de salida de su ' +
      'organización.',
  },
]

export const puntos = [
  // ------------------------------------------------------------ dominios
  {
    grupo: 'Dominios',
    metodo: 'GET',
    ruta: '/v1/dominios',
    acceso: 'llave · sesión',
    resumen: 'Los dominios de la organización, con cuántos agentes e impresoras tienen.',
    nota:
      'Un dominio agrupa computadoras, impresoras y llaves: una sucursal, un ' +
      'almacén, un cliente. Una llave acotada a un dominio solo se ve a sí misma.',
  },
  {
    grupo: 'Dominios',
    metodo: 'POST',
    ruta: '/v1/dominios',
    acceso: 'admin',
    resumen: 'Crea un dominio.',
    cuerpo: [
      ['nombre', 'texto', 'sí', ''],
      ['slug', 'texto', 'no', 'Se deriva del nombre si no lo mandas'],
      ['descripcion', 'texto', 'no', ''],
    ],
  },
  {
    grupo: 'Dominios',
    metodo: 'PATCH',
    ruta: '/v1/dominios/:id',
    acceso: 'admin',
    resumen: 'Cambia nombre o descripción.',
  },
  {
    grupo: 'Dominios',
    metodo: 'DELETE',
    ruta: '/v1/dominios/:id',
    acceso: 'admin',
    resumen: 'Borra un dominio vacío.',
    nota:
      'Con agentes o llaves dentro devuelve `409 dominio_en_uso`: borrarlo los ' +
      'dejaría fuera de toda regla de acceso, imprimiendo igual.',
  },

  // ------------------------------------------------------------- sesión
  {
    grupo: 'Sesión',
    metodo: 'POST',
    ruta: '/v1/auth/registro',
    acceso: 'público',
    resumen: 'Crea una organización y su primer usuario administrador.',
    nota: 'Solo si el hub corre con PRINT_REGISTRO=abierto.',
    cuerpo: [
      ['correo', 'texto', 'sí', 'Único en el hub'],
      ['clave', 'texto', 'sí', 'Ocho caracteres o más'],
      ['organizacion', 'texto', 'sí', 'Nombre visible'],
      ['nombre', 'texto', 'no', 'De la persona'],
    ],
    respuesta: `{ "token": "eyJ...", "usuario": { "id": 1, "rol": "admin", "org": 1 } }`,
  },
  {
    grupo: 'Sesión',
    metodo: 'POST',
    ruta: '/v1/auth/login',
    acceso: 'público',
    resumen: 'Devuelve el token de sesión.',
    cuerpo: [
      ['correo', 'texto', 'sí', ''],
      ['clave', 'texto', 'sí', ''],
    ],
    respuesta: `{ "token": "eyJ...", "usuario": { … } }`,
  },
  {
    grupo: 'Sesión',
    metodo: 'POST',
    ruta: '/v1/auth/recuperar',
    acceso: 'público',
    resumen: '«¿Olvidaste tu clave?»: manda un enlace para poner una clave nueva.',
    cuerpo: [['correo', 'texto', 'sí', '']],
    nota:
      'Si el correo tiene cuenta y su organización tiene correo de salida, le llega ' +
      'un enlace `/#/activar/<token>` que sirve una vez y **vence en 1 hora**. La ' +
      'clave de antes sigue valiendo hasta que se use. La respuesta es siempre la ' +
      'misma, exista o no el correo, y el envío pasa después de contestar: ni el ' +
      'contenido ni lo que tarda dicen qué correos tienen cuenta. Cinco pedidos por ' +
      'minuto por IP y tres por hora por correo; pasado eso, `429 demasiados_intentos`. ' +
      'El enlace se arma con `PRINT_URL_PUBLICA`: sin ella, el hub no manda nada y ' +
      '`/salud` dice `recuperar: false`.',
    respuesta: `{ "pedido": true }`,
  },
  {
    grupo: 'Sesión',
    metodo: 'GET',
    ruta: '/v1/auth/invitacion/:token',
    acceso: 'público',
    resumen: 'Si un enlace para poner clave sirve, y para qué correo.',
    nota:
      'Lo usa la página del enlace antes de pedir la clave. Un token que no existe ' +
      'o ya se usó da `404 invitacion_invalida`.',
    respuesta: `{ "correo": "ana@ejemplo.do", "vigente": true }`,
  },
  {
    grupo: 'Sesión',
    metodo: 'POST',
    ruta: '/v1/auth/activar',
    acceso: 'público',
    resumen: 'Pone la clave con un enlace y abre la sesión.',
    cuerpo: [
      ['token', 'texto', 'sí', 'El del enlace'],
      ['clave', 'texto', 'sí', 'Ocho caracteres o más'],
    ],
    nota:
      'El enlace sirve una vez. Vencido o ya usado: `410 invitacion_vencida`.',
    respuesta: `{ "token": "eyJ...", "usuario": { … } }`,
  },
  {
    grupo: 'Sesión',
    metodo: 'GET',
    ruta: '/v1/yo',
    acceso: 'sesión',
    resumen: 'Quién soy y a qué organización pertenezco.',
  },

  // ---------------------------------------------------------- impresoras
  {
    grupo: 'Impresoras',
    metodo: 'GET',
    ruta: '/v1/impresoras',
    acceso: 'llave · sesión',
    resumen: 'Las impresoras de la organización, con su estado actual.',
    consulta: [['agente', 'número', 'no', 'Filtra por agente']],
    respuesta: `{
  "impresoras": [{
    "id": 7,
    "nombre": "Etiquetas recepción",
    "sistema": "ZDesigner GK420d",
    "estado": "lista",
    "detalle": "",
    "cola": 0,
    "formatos": ["raw", "texto"],
    "protocolo": null,
    "protocolo_modelo": "zpl",
    "protocolo_auto": "zpl",
    "protocolo_efectivo": "zpl",
    "agente": 2,
    "agente_conectado": true
  }]
}`,
    nota:
      'Estados: `lista`, `ocupada`, `pausada`, `sin_papel`, `error`, `ausente` ' +
      '(el agente ya no la ve) y `sin_agente` (la computadora está apagada).\n\n' +
      '**Protocolo** —cómo se le habla a la impresora—: `driver` (PDF por su driver, ' +
      'el estándar: sirve con cualquier impresora que tenga driver, como la página de ' +
      'prueba de Windows), `zpl`, `epl`, `dp` (Direct Protocol) o `texto`. Se fija una ' +
      'vez por modelo (`protocolo_modelo`, para todas las de ese modelo de la ' +
      'organización) o para una cola sola (`protocolo`, que manda sobre el del modelo). ' +
      'Sin ninguno vale el que deduce el agente (`protocolo_auto`, desde el agente ' +
      '0.5.0). `protocolo_efectivo` es el que se usa.',
  },
  {
    grupo: 'Impresoras',
    metodo: 'GET',
    ruta: '/v1/impresoras/:id',
    acceso: 'llave · sesión',
    resumen: 'Una impresora.',
  },
  {
    grupo: 'Impresoras',
    metodo: 'PATCH',
    ruta: '/v1/impresoras/:id',
    acceso: 'sesión',
    resumen:
      'Cambia el nombre visible, la marca de predeterminada o el protocolo. ' +
      '`protocolo_modelo` fija el de todas las del modelo de esta impresora (lo normal ' +
      'la primera vez que aparece un modelo); `protocolo`, el de esta cola sola. `null` ' +
      'lo quita. Un valor fuera de la lista da 400 `protocolo_invalido`; fijar el del ' +
      'modelo de una impresora sin modelo, 409 `sin_modelo`. Los agentes conectados ' +
      'reciben el cambio al momento.',
    cuerpo: [
      ['nombre', 'texto', 'no', 'El nombre con el que la ve la gente'],
      ['predeterminada', 'sí/no', 'no', 'Una por agente'],
      ['protocolo_modelo', 'texto o null', 'no', '`driver`, `zpl`, `epl`, `dp` o `texto`, para todas las de su modelo'],
      ['protocolo', 'texto o null', 'no', 'Lo mismo, solo para esta cola'],
    ],
  },

  // ------------------------------------------------------------ trabajos
  {
    grupo: 'Trabajos',
    metodo: 'POST',
    ruta: '/v1/trabajos',
    acceso: 'llave · sesión',
    resumen: 'Manda algo a imprimir.',
    cuerpo: [
      ['impresora', 'número', 'sí*', 'Id de la impresora'],
      ['impresora_nombre', 'texto', 'sí*', 'Alternativa al id: nombre visible o del sistema'],
      ['formato', 'texto', 'no', '`raw` (por defecto), `pdf`, `imagen`, `texto` o `prueba`'],
      ['contenido_b64', 'texto', 'sí*', 'El contenido en base64'],
      ['texto', 'texto', 'sí*', 'Alternativa: texto plano, sin codificar'],
      ['copias', 'número', 'no', '1 a 999'],
      ['nombre', 'texto', 'no', 'Cómo se llama el trabajo en la cola'],
      ['idempotencia', 'texto', 'no', 'Llave para que un reintento no imprima dos veces'],
      ['opciones', 'objeto', 'no', 'Opciones del driver, p. ej. `{"cups.media": "A4"}`'],
    ],
    nota:
      '`impresora` o `impresora_nombre`, y `contenido_b64` o `texto`. Si mandas ' +
      '`idempotencia` y esa llave ya existe, se devuelve el trabajo anterior con ' +
      '`"repetido": true` y **no se imprime otra vez**.\n\n' +
      'El formato `prueba` va sin contenido: la arma el agente en el lenguaje ' +
      'que hable esa impresora (EPL, ZPL o texto). Es la única forma de que una ' +
      'prueba funcione tanto en una láser como en una etiquetadora.',
    respuesta: `{
  "id": 128,
  "estado": "enviado",
  "impresora": 7,
  "agente_conectado": true
}`,
    ejemplo: `curl -X POST https://TU-HUB/v1/trabajos \\
  -H "authorization: Bearer cpk_..." \\
  -H "content-type: application/json" \\
  -d '{
        "impresora_nombre": "Etiquetas recepción",
        "formato": "raw",
        "contenido_b64": "XlhBXkZPNTAsNTBeQTBOLDQwXkZESG9sYV5GU15YWg==",
        "idempotencia": "mov-8891"
      }'`,
  },
  {
    grupo: 'Trabajos',
    metodo: 'GET',
    ruta: '/v1/trabajos',
    acceso: 'llave · sesión',
    resumen: 'Los últimos trabajos.',
    consulta: [
      ['estado', 'texto', 'no', 'en_cola, enviado, imprimiendo, hecho, fallido, cancelado'],
      ['impresora', 'número', 'no', ''],
      ['limite', 'número', 'no', 'Hasta 200; por defecto 50'],
    ],
  },
  {
    grupo: 'Trabajos',
    metodo: 'GET',
    ruta: '/v1/trabajos/:id',
    acceso: 'llave · sesión',
    resumen: 'Un trabajo con su historia: cuándo se encoló, se envió y qué contestó el agente.',
  },
  {
    grupo: 'Trabajos',
    metodo: 'POST',
    ruta: '/v1/trabajos/:id/cancelar',
    acceso: 'llave · sesión',
    resumen: 'Cancela un trabajo que todavía no salió.',
    nota: 'Solo mientras está `en_cola` o `enviado`. Lo que ya imprimió, imprimió.',
  },

  // ------------------------------------------------------------- agentes
  {
    grupo: 'Agentes',
    metodo: 'GET',
    ruta: '/v1/agentes',
    acceso: 'llave · sesión',
    resumen: 'Las computadoras con agente y si están conectadas ahora mismo.',
  },
  {
    grupo: 'Agentes',
    metodo: 'POST',
    ruta: '/v1/agentes/registrar',
    acceso: 'llave (agentes:registrar)',
    resumen: 'Da de alta una computadora y devuelve su credencial.',
    nota:
      'Lo llama el agente solo al instalarse; no hay que ejecutarlo a mano. Es ' +
      'idempotente por `huella`: reinstalar renueva la credencial en vez de ' +
      'duplicar el agente.',
    cuerpo: [
      ['huella', 'texto', 'sí', 'Identidad estable de la máquina'],
      ['nombre', 'texto', 'no', ''],
      ['dominio', 'número o slug', 'no', 'Solo si la llave no está acotada ya'],
      ['plataforma', 'texto', 'no', ''],
      ['version', 'texto', 'no', ''],
    ],
    respuesta: `{ "agente": 2, "credencial": "cag_2_..." }`,
  },
  {
    grupo: 'Agentes',
    metodo: 'PATCH',
    ruta: '/v1/agentes/:id',
    acceso: 'sesión',
    resumen: 'Le cambia el nombre.',
  },
  {
    grupo: 'Agentes',
    metodo: 'POST',
    ruta: '/v1/agentes/:id/revocar',
    acceso: 'admin',
    resumen: 'Le quita la credencial y lo desconecta al instante.',
  },
  {
    grupo: 'Agentes',
    metodo: 'DELETE',
    ruta: '/v1/agentes/:id',
    acceso: 'admin',
    resumen: 'Lo borra junto con sus impresoras.',
  },

  // -------------------------------------------------------------- llaves
  {
    grupo: 'Llaves',
    metodo: 'GET',
    ruta: '/v1/llaves',
    acceso: 'admin',
    resumen: 'Las llaves de la organización (nunca el secreto).',
  },
  {
    grupo: 'Llaves',
    metodo: 'POST',
    ruta: '/v1/llaves',
    acceso: 'admin',
    resumen: 'Crea una llave. El secreto se enseña una sola vez.',
    cuerpo: [
      ['nombre', 'texto', 'sí', 'Para saber después qué la usa'],
      ['permisos', 'lista', 'no', 'Por defecto: imprimir, leer impresoras y registrar agentes'],
      ['dominio', 'número o slug', 'no', 'Acota la llave a un dominio; vacío = toda la organización'],
    ],
    respuesta: `{ "id": 3, "prefijo": "ab12cd34", "llave": "cpk_ab12cd34_…" }`,
  },
  {
    grupo: 'Llaves',
    metodo: 'DELETE',
    ruta: '/v1/llaves/:id',
    acceso: 'admin',
    resumen: 'La revoca. La fila queda para saber qué imprimió.',
  },

  // ------------------------------------------------------------ usuarios
  {
    grupo: 'Usuarios',
    metodo: 'GET',
    ruta: '/v1/usuarios',
    acceso: 'admin',
    resumen: 'Los usuarios de la organización.',
    nota:
      '`invitacion_vence` dice hasta cuándo vale el enlace para poner clave que ' +
      'tenga pendiente cada persona (null si no tiene).',
  },
  {
    grupo: 'Usuarios',
    metodo: 'POST',
    ruta: '/v1/usuarios',
    acceso: 'admin',
    resumen: 'Da de alta a alguien.',
    cuerpo: [
      ['correo', 'texto', 'sí', ''],
      ['clave', 'texto', 'sí', ''],
      ['rol', 'texto', 'no', '`admin` u `operador`'],
      ['nombre', 'texto', 'no', ''],
    ],
  },
  {
    grupo: 'Usuarios',
    metodo: 'POST',
    ruta: '/v1/usuarios/:id/clave',
    acceso: 'sesión',
    resumen: 'Cambia una clave. La propia siempre; la de otros, con rol admin.',
  },
  {
    grupo: 'Usuarios',
    metodo: 'POST',
    ruta: '/v1/usuarios/:id/invitacion',
    acceso: 'admin',
    resumen: 'Un enlace para que esa persona ponga su clave ella misma.',
    nota:
      'Sirve una vez y vence en siete días; invalida el enlace anterior de esa ' +
      'persona, y su clave sigue valiendo hasta que lo use. El enlace se devuelve ' +
      'una sola vez. Si la organización tiene correo de salida, además se le manda: ' +
      '`envio` es `null` sin correo de salida (compártelo tú), `{"enviado": true, ' +
      '"para": …}` o `{"enviado": false, "error": …, "detalle": …}` si el servidor ' +
      'de correo no lo aceptó (el enlace sirve igual).',
    respuesta: `{
  "enlace": "https://TU-HUB/#/activar/…",
  "vence": "2026-10-16T12:00:00.000Z",
  "envio": { "enviado": true, "para": "ana@ejemplo.do" }
}`,
  },
  {
    grupo: 'Usuarios',
    metodo: 'DELETE',
    ruta: '/v1/usuarios/:id',
    acceso: 'admin',
    resumen: 'Da de baja a alguien.',
  },

  // -------------------------------------------------------- organización
  {
    grupo: 'Organización',
    metodo: 'GET',
    ruta: '/v1/org/correo',
    acceso: 'admin',
    resumen: 'El correo de salida de la organización, sin la clave.',
    nota:
      'Por él salen los enlaces para poner clave: el de «¿Olvidaste tu clave?» y el ' +
      'que genera un admin. La clave del servidor de correo no vuelve nunca: ' +
      '`clave_puesta` dice si hay una.',
    respuesta: `{
  "host": "smtp.gmail.com",
  "puerto": 587,
  "seguridad": "starttls",
  "remitente": "avisos@tu-empresa.com",
  "usuario": "avisos@tu-empresa.com",
  "nombre": "print-server de tu empresa",
  "clave_puesta": true,
  "configurado": true
}`,
  },
  {
    grupo: 'Organización',
    metodo: 'PUT',
    ruta: '/v1/org/correo',
    acceso: 'admin',
    resumen: 'Pone o cambia el correo de salida.',
    cuerpo: [
      ['host', 'texto', 'sí', 'El servidor SMTP'],
      ['puerto', 'número', 'sí', '465 con `tls`, 587 con `starttls`'],
      ['seguridad', 'texto', 'no', '`starttls` (por defecto), `tls` o `ninguna` (solo en una red propia)'],
      ['remitente', 'texto', 'sí', 'La dirección del «De:»'],
      ['usuario', 'texto', 'no', 'Sin usuario no se autentica'],
      ['clave', 'texto', 'no', 'Vacía o sin mandar: se queda la que estaba'],
      ['nombre', 'texto', 'no', 'El nombre que se ve en el «De:»'],
      ['quitar', 'sí/no', 'no', '`true` borra el correo de salida'],
    ],
    nota:
      'Devuelve lo mismo que el GET. Sin correo de salida en ninguna organización, ' +
      'la entrada del panel no ofrece «¿Olvidaste tu clave?».',
  },
  {
    grupo: 'Organización',
    metodo: 'POST',
    ruta: '/v1/org/correo/prueba',
    acceso: 'admin',
    resumen: 'Manda un correo de prueba a quien lo pide.',
    nota:
      'Va al correo de la persona con sesión (con una llave no hay a quién: ' +
      '`400 sin_destinatario`). Si el servidor no lo acepta, `502` con lo que ' +
      'contestó: `correo_autenticacion`, `correo_conexion`, `correo_tls`, ' +
      '`correo_sin_starttls`, `correo_rechazado` o `correo_tiempo`.',
    respuesta: `{ "enviado": true, "para": "ana@ejemplo.do" }`,
  },

  // ----------------------------------------------------------- descargas
  {
    grupo: 'Descargas',
    metodo: 'GET',
    ruta: '/v1/descargas',
    acceso: 'público',
    resumen: 'Qué ejecutables del agente publica este hub, con tamaño y sha256.',
    nota:
      'Público a propósito: una máquina que va a instalar el agente todavía no ' +
      'tiene credencial ninguna.',
    respuesta: `{
  "descargas": [{
    "archivo": "print-server-agente-linux-x64",
    "url": "/descargas/print-server-agente-linux-x64",
    "sistema": "linux",
    "bytes": 7617144,
    "sha256": "…"
  }]
}`,
  },
  {
    grupo: 'Descargas',
    metodo: 'GET',
    ruta: '/descargas/:archivo',
    acceso: 'público',
    resumen: 'Baja un ejecutable o el script de instalación.',
  },
  {
    grupo: 'Descargas',
    metodo: 'POST',
    ruta: '/v1/descargas/:archivo',
    acceso: 'admin de la organización publicadora',
    resumen: 'Publica un ejecutable. El cuerpo son los bytes, sin envolver.',
    nota:
      'Solo se aceptan los nombres conocidos del agente y los dos instaladores: ' +
      'la carpeta se sirve sin credencial, y admitir un nombre cualquiera sería ' +
      'admitir escritura en ella. Y solo publica la organización que levantó el ' +
      'hub (`PRINT_ORG_PUBLICADORA`, por defecto 1): las descargas son del hub ' +
      'entero, no de una organización. Lo usan `agente/publicar.ps1` y ' +
      '`agente/publicar.sh`; **compara el sha256 que devuelve** con el del ' +
      'archivo local antes de darlo por publicado.',
    respuesta: `{ "archivo": "…", "url": "/descargas/…", "bytes": 7617144, "sha256": "…" }`,
    ejemplo: `curl -X POST https://TU-HUB/v1/descargas/print-server-agente-linux-x64 \\
  -H "authorization: Bearer cpk_admin" \\
  -H "content-type: application/octet-stream" \\
  --data-binary @print-server-agente-linux-x64`,
  },
  {
    grupo: 'Descargas',
    metodo: 'DELETE',
    ruta: '/v1/descargas/:archivo',
    acceso: 'admin de la organización publicadora',
    resumen: 'Retira un ejecutable publicado.',
  },

  // --------------------------------------------------------------- salud
  {
    grupo: 'Salud',
    metodo: 'GET',
    ruta: '/salud',
    acceso: 'público',
    resumen: 'Comprueba que el hub responde y llega a su base de datos.',
    nota:
      '`recuperar` dice si la entrada puede ofrecer «¿Olvidaste tu clave?»: hace ' +
      'falta que alguna organización tenga correo de salida y que el hub tenga ' +
      '`PRINT_URL_PUBLICA`.',
    respuesta: `{ "ok": true, "servicio": "print-server", "recuperar": true }`,
  },
]

export const errores = [
  ['401', '`no_autenticado`', 'Falta la credencial o no vale'],
  ['403', '`sin_permiso` · `requiere_admin`', 'La llave no llega a tanto'],
  ['404', '`impresora_no_encontrada`', 'Ni por id ni por nombre'],
  ['404', '`invitacion_invalida`', 'Ese enlace para poner clave no existe o ya se usó'],
  ['410', '`invitacion_vencida`', 'El enlace venció o ya se usó: pide otro'],
  ['409', '`impresora_ambigua`', 'Dos impresoras con ese nombre; manda el id'],
  ['409', '`dominio_en_uso`', 'El dominio todavía tiene agentes o llaves'],
  ['403', '`no_publicas_aqui`', 'Publicar descargas es de la organización que levantó el hub'],
  ['409', '`impresora_ausente`', 'El agente ya no la ve en su sistema'],
  ['413', '`contenido_grande`', 'Pasa del tope del hub'],
  ['415', '`formato_no_soportado`', 'Esa impresora no admite ese formato'],
  ['429', '`demasiados_intentos`', 'Freno del login, del registro y de «¿Olvidaste tu clave?»'],
  ['502', '`correo_*`', 'El servidor de correo de la organización no aceptó el envío'],
]

export const grupos = [...new Set(puntos.map((p) => p.grupo))]
