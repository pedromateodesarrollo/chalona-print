<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { api } from '../api.js'

const impresoras = ref([])
const error = ref('')

/// Id del agente por el que se filtra, o '' para todas.
const computadora = ref('')
const editando = ref(null)
const nombreNuevo = ref('')
const probando = ref(null)
const mensaje = ref('')
let temporizador

const textos = {
  lista: 'Lista',
  ocupada: 'Imprimiendo',
  pausada: 'En pausa',
  sin_papel: 'Sin papel',
  error: 'Con error',
  ausente: 'Ya no está en el sistema',
  sin_agente: 'Computadora apagada',
  desconocida: 'Desconocida',
}
const color = (e) =>
  e === 'lista' ? 'ok' : ['error', 'sin_papel', 'ausente', 'sin_agente'].includes(e) ? 'mal' : 'tibio'

const conexiones = { usb: 'USB', red: 'Red', puerto: 'Puerto serie', archivo: 'Archivo' }

/// Lo que permite reconocerla sin saberse el nombre de la cola.
function identidad(i) {
  return [
    [i.fabricante, i.modelo].filter(Boolean).join(' '),
    conexiones[i.conexion] || '',
    i.serie ? `serie ${i.serie}` : '',
  ]
    .filter(Boolean)
    .join(' · ')
}

/// Recién aparecida: es la que alguien acaba de enchufar y está buscando.
const esNueva = (i) => Date.now() - new Date(i.creado).getTime() < 30 * 60 * 1000

/// Las computadoras que aparecen, sacadas de las propias impresoras.
///
/// Se derivan de la lista en vez de pedir `/v1/agentes` aparte: así las
/// opciones siempre son exactamente las que tienen algo que enseñar, y no
/// aparece en el desplegable una máquina de la que no se ve ni una impresora.
const computadoras = computed(() => {
  const vistas = new Map()
  for (const i of impresoras.value) {
    if (!vistas.has(i.agente)) vistas.set(i.agente, i.agente_nombre)
  }
  return [...vistas].map(([id, nombre]) => ({ id, nombre }))
})

/// El filtro se aplica aquí y no en el API a propósito: pidiendo la lista
/// completa, el desplegable conserva todas las opciones y cambiar de
/// computadora es instantáneo, sin otra vuelta al servidor.
const visibles = computed(() =>
  computadora.value === ''
    ? impresoras.value
    : impresoras.value.filter((i) => String(i.agente) === computadora.value),
)

async function carga() {
  try {
    impresoras.value = (await api.get('/v1/impresoras')).impresoras
    // Si la computadora filtrada desaparece —se dio de baja el agente—, se
    // vuelve a «todas» en vez de dejar la tabla vacía sin explicación.
    if (computadora.value && !computadoras.value.some((c) => String(c.id) === computadora.value)) {
      computadora.value = ''
    }
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function renombra(i) {
  await api.patch(`/v1/impresoras/${i.id}`, { nombre: nombreNuevo.value })
  editando.value = null
  await carga()
}

/// Imprimir es la única forma de saber cuál de las cinco es la de enfrente.
///
/// Va como formato `prueba` y sin contenido: lo arma el agente, que es el
/// único que sabe si esa impresora habla EPL, ZPL o texto. Mandar texto plano
/// a una etiquetadora no imprimía nada y el trabajo quedaba en «hecho».
async function prueba(i) {
  probando.value = i.id
  mensaje.value = ''
  try {
    const t = await api.post('/v1/trabajos', {
      impresora: i.id,
      formato: 'prueba',
      nombre: 'Prueba desde el panel',
    })
    mensaje.value = `Prueba enviada a «${i.nombre}» (trabajo ${t.id}).`
  } catch (e) {
    mensaje.value = `No se pudo: ${e.message}`
  } finally {
    probando.value = null
  }
}

// Se refresca solo: el estado cambia cuando alguien echa papel al otro lado,
// no cuando aquí se pulsa un botón.
onMounted(() => {
  carga()
  temporizador = setInterval(carga, 5000)
})
onUnmounted(() => clearInterval(temporizador))
</script>

<template>
  <div class="cabecera-seccion">
    <h2>Impresoras</h2>
    <!-- Con una sola computadora el filtro sobra y solo estorba. -->
    <select v-if="computadoras.length > 1" v-model="computadora" style="width: auto">
      <option value="">Todas las computadoras</option>
      <option v-for="c in computadoras" :key="c.id" :value="String(c.id)">
        {{ c.nombre }}
      </option>
    </select>
  </div>
  <p v-if="error" class="aviso">{{ error }}</p>
  <p v-if="mensaje" class="exito">{{ mensaje }}</p>

  <p v-if="!impresoras.length" class="apagado">
    Todavía no hay ninguna. Instala el agente en la computadora que las tiene y
    aparecerán solas.
  </p>
  <p v-else-if="!visibles.length" class="apagado">
    Esa computadora no tiene ninguna impresora ahora mismo.
  </p>

  <table v-else>
    <thead>
      <tr>
        <th>Impresora</th><th>Estado</th><th>Computadora</th>
        <th>Dominio</th><th>Cola</th><th></th>
      </tr>
    </thead>
    <tbody>
      <tr v-for="i in visibles" :key="i.id">
        <td>
          <template v-if="editando === i.id">
            <input v-model="nombreNuevo" @keyup.enter="renombra(i)" style="max-width: 220px" />
          </template>
          <template v-else>
            <strong>{{ i.nombre }}</strong>
            <span v-if="esNueva(i)" class="nueva">nueva</span>
            <div v-if="identidad(i)" class="apagado" style="font-size: 13px">
              {{ identidad(i) }}
            </div>
            <div class="apagado" style="font-size: 12px">
              <code>{{ i.sistema }}</code> · {{ (i.formatos || []).join(', ') }}
            </div>
          </template>
        </td>
        <td>
          <span class="estado">
            <span class="punto" :class="color(i.estado)"></span>
            {{ textos[i.estado] || i.estado }}
          </span>
          <div v-if="i.detalle" class="apagado" style="font-size: 13px">{{ i.detalle }}</div>
        </td>
        <td>
          {{ i.agente_nombre }}
          <!-- «agente» explícito: en una fila de impresora, un «conectada» a
               secas se lee como si hablara de la impresora, y es del agente. -->
          <div class="apagado" style="font-size: 13px">
            {{ i.agente_conectado ? 'agente conectado' : 'agente sin conexión' }}
          </div>
        </td>
        <td class="apagado">{{ i.dominio_nombre || '—' }}</td>
        <td>{{ i.cola }}</td>
        <td style="white-space: nowrap">
          <button
            class="boton suave chico"
            :disabled="probando === i.id"
            @click="prueba(i)"
          >
            {{ probando === i.id ? '…' : 'Prueba' }}
          </button>
          <button
            class="boton suave chico"
            style="margin-left: 6px"
            @click="editando === i.id ? renombra(i) : ((editando = i.id), (nombreNuevo = i.nombre))"
          >
            {{ editando === i.id ? 'Guardar' : 'Renombrar' }}
          </button>
        </td>
      </tr>
    </tbody>
  </table>
</template>
