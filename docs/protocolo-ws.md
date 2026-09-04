# Protocolo del WebSocket (hub ↔ agente)

El agente abre la conexión; el hub nunca marca. Es lo que hace que esto
funcione detrás del router de un cliente sin abrir puertos.

```
GET /agente/ws
authorization: Bearer cag_<id>_<secreto>
```

También se acepta `?token=cag_...` en la URL, para herramientas y proxies que
no dejan poner cabeceras al abrir un WebSocket.

Todos los marcos son JSON con un campo `tipo`.

## Versión

El agente manda su versión de protocolo en el saludo. **Versión actual: 1.**

Un agente instalado en la computadora de una nave no se actualiza cuando uno
quiere: el hub tendrá que hablar con versiones viejas durante meses. Por eso el
número viaja desde el primer marco y el hub responde `hola_no` en vez de fallar
a medias.

## Agente → hub

### `hola`

Primer marco. Hasta que llega, el hub ignora todo lo demás.

```json
{
  "tipo": "hola",
  "protocolo": 1,
  "version": "0.1.0",
  "plataforma": "windows 11",
  "driver": "windows",
  "impresoras": [ { …inventario… } ]
}
```

### `latido` / `impresoras`

Cada 30 segundos, y cuando algo cambia. Lleva el inventario completo: lo que no
venga en la lista se marca `ausente` en el hub.

```json
{ "tipo": "latido", "impresoras": [
  { "sistema": "ZDesigner GK420d", "nombre": "ZDesigner GK420d",
    "estado": "lista", "detalle": "", "cola": 0,
    "predeterminada": true, "formatos": ["raw", "texto"] }
]}
```

Estados: `lista`, `ocupada`, `pausada`, `sin_papel`, `error`, `desconocida`.
Los dos que **solo pone el hub** son `ausente` (el agente ya no la ve) y
`sin_agente` (la computadora no está conectada).

### `ack`

Qué pasó con un trabajo. El agente solo puede moverlo a `imprimiendo`, `hecho`
o `fallido`.

```json
{ "tipo": "ack", "trabajo": 128, "estado": "hecho", "detalle": "" }
```

## Hub → agente

### `hola_ok` / `hola_no`

```json
{ "tipo": "hola_ok", "protocolo": 1, "agente": 2 }
{ "tipo": "hola_no", "motivo": "protocolo_incompatible", "hub": 1, "minima": 1 }
```

Ante `hola_no` el agente **no reintenta**: lo apunta en su log y para. Lo que
hace falta es actualizarlo, y reintentar solo taparía el aviso.

### `trabajo`

```json
{
  "tipo": "trabajo",
  "id": 128,
  "formato": "raw",
  "nombre": "etiqueta 8891",
  "impresora": "ZDesigner GK420d",
  "copias": 1,
  "opciones": {},
  "contenido_b64": "…"
}
```

### `cancelar`

```json
{ "tipo": "cancelar", "trabajo": 128 }
```

## Reentrega y duplicados

El hub reenvía los trabajos que quedaron en `enviado` cuando el agente vuelve a
conectarse: si la conexión se cortó entre el envío y el `ack`, nadie sabe si
llegó a imprimirse.

Quien resuelve la duda es el agente, que lleva en disco los ids de lo que ya
imprimió. Si le llega uno repetido, contesta `hecho` **sin volver a imprimir**.

El id se anota **antes** de mandar el `ack`. Al revés —ack primero— un corte de
luz entre las dos cosas dejaría el trabajo sin marcar y saldría dos veces.

## Cierre

El hub pone `pingInterval` de 30 s. Cuando una computadora se apaga de golpe,
el socket queda medio abierto y el ping lo cierra en un minuto; sin eso, el hub
seguiría mandándole trabajos a un agente fantasma.
