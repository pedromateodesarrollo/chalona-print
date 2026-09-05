/// Cliente del API. Guarda el token en localStorage y traduce los errores del
/// hub a excepciones con el mensaje que ya viene traducido del servidor.

const CLAVE_TOKEN = 'print-server-token'

export const sesion = {
  get token() { return localStorage.getItem(CLAVE_TOKEN) || '' },
  set token(v) {
    if (v) localStorage.setItem(CLAVE_TOKEN, v)
    else localStorage.removeItem(CLAVE_TOKEN)
  },
}

async function pide(metodo, ruta, cuerpo) {
  const r = await fetch(ruta, {
    method: metodo,
    headers: {
      'content-type': 'application/json',
      ...(sesion.token ? { authorization: `Bearer ${sesion.token}` } : {}),
    },
    body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
  })
  if (r.status === 204) return null
  const d = await r.json().catch(() => ({}))
  if (!r.ok) {
    // 401 con sesión guardada = el token caducó o el hub rotó su secreto.
    if (r.status === 401 && sesion.token) sesion.token = ''
    const e = new Error(d.mensaje || d.error || `Error ${r.status}`)
    e.codigo = d.error
    throw e
  }
  return d
}

export const api = {
  get: (r) => pide('GET', r),
  post: (r, c) => pide('POST', r, c),
  patch: (r, c) => pide('PATCH', r, c),
  del: (r) => pide('DELETE', r),
}
