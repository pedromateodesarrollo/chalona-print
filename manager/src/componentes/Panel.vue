<script setup>
import { ref, computed, onMounted } from 'vue'
import { api, sesion } from '../api.js'
import Agentes from './Agentes.vue'
import Impresoras from './Impresoras.vue'
import Trabajos from './Trabajos.vue'
import Llaves from './Llaves.vue'
import Dominios from './Dominios.vue'
import Descargas from './Descargas.vue'
import Usuarios from './Usuarios.vue'
import Organizacion from './Organizacion.vue'

const yo = ref(null)
const cargando = ref(true)
const seccion = ref('impresoras')

const modo = ref('entrar') // entrar | registrar | recuperar
const correo = ref('')
const clave = ref('')
const organizacion = ref('')
const error = ref('')
const enviando = ref(false)

// «¿Olvidaste tu clave?» solo aparece si el hub tiene por dónde mandar el
// enlace (`recuperar` de /salud: alguna organización con correo de salida).
// Ofrecerlo sin eso sería prometer un correo que no va a llegar.
const recuperar = ref(false)
const pedido = ref(false)

const secciones = computed(() => [
  ['impresoras', 'Impresoras', Impresoras],
  ['trabajos', 'Trabajos', Trabajos],
  ['agentes', 'Agentes', Agentes],
  ['instalar', 'Instalar agente', Descargas],
  ['dominios', 'Dominios', Dominios],
  ['llaves', 'Llaves de API', Llaves],
  ['usuarios', 'Usuarios', Usuarios],
  ...(yo.value?.rol === 'admin' ? [['organizacion', 'Organización', Organizacion]] : []),
])

onMounted(async () => {
  api.get('/salud').then((s) => (recuperar.value = s.recuperar === true)).catch(() => {})
  if (sesion.token) {
    try {
      yo.value = await api.get('/v1/yo')
    } catch {
      sesion.token = ''
    }
  }
  cargando.value = false
})

function cambiaModo(m) {
  modo.value = m
  error.value = ''
  pedido.value = false
}

async function pideEnlace() {
  error.value = ''
  enviando.value = true
  try {
    await api.post('/v1/auth/recuperar', { correo: correo.value })
    pedido.value = true
  } catch (e) {
    error.value = e.message
  } finally {
    enviando.value = false
  }
}

async function entra() {
  error.value = ''
  enviando.value = true
  try {
    const ruta = modo.value === 'entrar' ? '/v1/auth/login' : '/v1/auth/registro'
    const cuerpo =
      modo.value === 'entrar'
        ? { correo: correo.value, clave: clave.value }
        : { correo: correo.value, clave: clave.value, organizacion: organizacion.value }
    const d = await api.post(ruta, cuerpo)
    sesion.token = d.token
    yo.value = await api.get('/v1/yo')
  } catch (e) {
    error.value = e.message
  } finally {
    enviando.value = false
  }
}

function sale() {
  sesion.token = ''
  yo.value = null
  seccion.value = 'impresoras'
}
</script>

<template>
  <div v-if="cargando" class="contenedor" style="padding: 60px 22px">
    <p class="apagado">Cargando…</p>
  </div>

  <!-- ¿Olvidaste tu clave? -->
  <div v-else-if="!yo && modo === 'recuperar'" class="contenedor" style="padding: 56px 22px; max-width: 460px">
    <h1 style="font-size: 28px">Clave nueva</h1>
    <template v-if="pedido">
      <p class="exito">
        Si ese correo tiene cuenta, te llegó un enlace para poner una clave nueva.
        Vence en 1 hora. Si no llega, mira en el correo no deseado o pídele uno a
        quien administra.
      </p>
    </template>
    <template v-else>
      <p class="apagado">Te mandamos a tu correo un enlace para ponerla.</p>
      <form class="caja" @submit.prevent="pideEnlace">
        <label>Correo</label>
        <input v-model="correo" type="email" autocomplete="email" required />
        <p v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</p>
        <button class="boton" style="margin-top: 18px" :disabled="enviando">
          {{ enviando ? 'Un momento…' : 'Mandarme el enlace' }}
        </button>
      </form>
    </template>
    <p class="apagado" style="margin-top: 18px; font-size: 14px">
      <a href="#" @click.prevent="cambiaModo('entrar')">Volver a entrar</a>
    </p>
  </div>

  <!-- Entrar / crear organización -->
  <div v-else-if="!yo" class="contenedor" style="padding: 56px 22px; max-width: 460px">
    <h1 style="font-size: 28px">
      {{ modo === 'entrar' ? 'Entrar' : 'Crear organización' }}
    </h1>
    <p class="apagado">
      {{ modo === 'entrar'
        ? 'Con la cuenta de tu organización.'
        : 'Tu cuenta será la administradora.' }}
    </p>
    <form class="caja" @submit.prevent="entra">
      <template v-if="modo === 'registrar'">
        <label>Organización</label>
        <input v-model="organizacion" placeholder="Mi empresa" required />
      </template>
      <label>Correo</label>
      <input v-model="correo" type="email" autocomplete="email" required />
      <label>Clave</label>
      <input
        v-model="clave"
        type="password"
        :autocomplete="modo === 'entrar' ? 'current-password' : 'new-password'"
        required
        minlength="8"
      />
      <p v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</p>
      <button class="boton" style="margin-top: 18px" :disabled="enviando">
        {{ enviando ? 'Un momento…' : modo === 'entrar' ? 'Entrar' : 'Crear' }}
      </button>
    </form>
    <p v-if="modo === 'entrar' && recuperar" style="margin-top: 14px; font-size: 14px">
      <a href="#" @click.prevent="cambiaModo('recuperar')">¿Olvidaste tu clave?</a>
    </p>
    <p class="apagado" style="margin-top: 18px; font-size: 14px">
      <a href="#" @click.prevent="cambiaModo(modo === 'entrar' ? 'registrar' : 'entrar')">
        {{ modo === 'entrar' ? 'Crear una organización nueva' : 'Ya tengo cuenta' }}
      </a>
    </p>
  </div>

  <!-- Panel -->
  <div v-else class="app">
    <aside class="lateral">
      <button
        v-for="[id, titulo] in secciones"
        :key="id"
        :class="{ activo: seccion === id }"
        @click="seccion = id"
      >
        {{ titulo }}
      </button>
      <hr style="border: 0; border-top: 1px solid var(--borde); margin: 14px 0" />
      <button @click="sale">Salir</button>
    </aside>

    <main class="contenido">
      <p class="apagado" style="font-size: 14px; margin-bottom: 14px">
        {{ yo.organizacion }} · {{ yo.correo }} ({{ yo.rol }})
      </p>
      <component
        :is="(secciones.find((s) => s[0] === seccion) || secciones[0])[2]"
        :yo="yo"
      />
    </main>
  </div>
</template>
