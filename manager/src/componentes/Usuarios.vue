<script setup>
import { ref, onMounted } from 'vue'
import { api } from '../api.js'

const props = defineProps({ yo: Object })
const usuarios = ref([])
const error = ref('')
const nuevo = ref({ correo: '', clave: '', rol: 'operador', nombre: '' })
const confirmando = ref(null)
const cambiando = ref(null)
const claveNueva = ref('')

// El enlace para que alguien ponga su clave él mismo. Sale por el correo de
// salida de la organización si lo hay (`envio`); si no, o si el correo no
// salió, se enseña para compartirlo a mano. Se ve una sola vez: el hub lo
// guarda hasheado.
const enlace = ref(null) // { correo, enlace, envio }
const pidiendo = ref(null)
const copiado = ref(false)

async function carga() {
  try {
    usuarios.value = (await api.get('/v1/usuarios')).usuarios
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function crea() {
  try {
    await api.post('/v1/usuarios', nuevo.value)
    nuevo.value = { correo: '', clave: '', rol: 'operador', nombre: '' }
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function cambiaClave(u) {
  try {
    await api.post(`/v1/usuarios/${u.id}/clave`, { clave: claveNueva.value })
    cambiando.value = null
    claveNueva.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function mandaEnlace(u) {
  error.value = ''
  enlace.value = null
  pidiendo.value = u.id
  try {
    const r = await api.post(`/v1/usuarios/${u.id}/invitacion`)
    enlace.value = { correo: u.correo, ...r }
    await carga()
  } catch (e) {
    error.value = e.message
  } finally {
    pidiendo.value = null
  }
}

async function copia() {
  try {
    await navigator.clipboard.writeText(enlace.value.enlace)
    copiado.value = true
    setTimeout(() => (copiado.value = false), 2000)
  } catch { /* está a la vista */ }
}

async function borra(u) {
  if (confirmando.value !== u.id) {
    confirmando.value = u.id
    setTimeout(() => (confirmando.value === u.id ? (confirmando.value = null) : null), 4000)
    return
  }
  try {
    await api.del(`/v1/usuarios/${u.id}`)
    confirmando.value = null
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

const hora = (s) => (s ? new Date(s).toLocaleString() : 'nunca')
onMounted(carga)
</script>

<template>
  <div class="cabecera-seccion"><h2>Usuarios</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div class="tarjeta" style="margin-bottom: 20px" v-if="props.yo.rol === 'admin'">
    <h3>Dar de alta</h3>
    <div style="display: flex; gap: 10px; flex-wrap: wrap; align-items: flex-end">
      <div style="flex: 2; min-width: 200px">
        <label>Correo</label>
        <input v-model="nuevo.correo" type="email" />
      </div>
      <div style="flex: 1; min-width: 150px">
        <label>Clave</label>
        <input v-model="nuevo.clave" type="password" minlength="8" />
      </div>
      <div style="flex: 1; min-width: 130px">
        <label>Rol</label>
        <select v-model="nuevo.rol">
          <option value="operador">Operador</option>
          <option value="admin">Administrador</option>
        </select>
      </div>
      <button class="boton" @click="crea" :disabled="!nuevo.correo || nuevo.clave.length < 8">
        Crear
      </button>
    </div>
  </div>

  <div v-if="enlace" class="exito">
    <template v-if="enlace.envio?.enviado">
      Le mandamos a <strong>{{ enlace.correo }}</strong> un enlace para poner su clave.
      Sirve una vez y vence en 7 días; hasta que lo use, su clave de antes sigue valiendo.
    </template>
    <template v-else-if="enlace.envio">
      El correo a {{ enlace.correo }} no salió ({{ enlace.envio.detalle || enlace.envio.error }}).
      Compártele este enlace por otro lado. Sirve una vez y vence en 7 días.
    </template>
    <template v-else>
      Tu organización no tiene correo de salida (Organización): compártele este enlace a
      {{ enlace.correo }}. Sirve una vez y vence en 7 días.
    </template>
    <div class="secreto">{{ enlace.enlace }}</div>
    <div class="acciones-fila" style="margin-top: 10px">
      <button class="boton suave chico" @click="copia">{{ copiado ? 'Copiado' : 'Copiar' }}</button>
      <button class="boton suave chico" @click="enlace = null">Listo</button>
    </div>
  </div>

  <table class="tarjetas-movil">
    <thead>
      <tr><th>Correo</th><th>Rol</th><th>Último acceso</th><th></th></tr>
    </thead>
    <tbody>
      <tr v-for="u in usuarios" :key="u.id">
        <td>
          {{ u.correo }}
          <span v-if="u.id === props.yo.id" class="apagado">(tú)</span>
        </td>
        <td class="apagado" data-titulo="Rol">{{ u.rol }}</td>
        <td class="apagado" style="font-size: 13px" data-titulo="Último acceso">
          {{ hora(u.ultimo_acceso) }}
          <div v-if="u.invitacion_vence && new Date(u.invitacion_vence) > new Date()">
            Enlace para poner clave hasta {{ hora(u.invitacion_vence) }}
          </div>
        </td>
        <td>
          <!-- Los botones bajan de línea en un teléfono en vez de ensanchar la tabla. -->
          <div class="acciones-fila" style="margin-top: 0">
            <template v-if="cambiando === u.id">
              <input
                v-model="claveNueva"
                type="password"
                placeholder="Clave nueva"
                style="max-width: 170px; display: inline-block"
                @keyup.enter="cambiaClave(u)"
              />
              <button class="boton chico" @click="cambiaClave(u)">Guardar</button>
            </template>
            <template v-else>
              <button class="boton suave chico" @click="cambiando = u.id">Clave</button>
              <button
                v-if="props.yo.rol === 'admin'"
                class="boton suave chico"
                :disabled="pidiendo === u.id"
                title="Un enlace para que ponga su clave él mismo"
                @click="mandaEnlace(u)"
              >
                {{ pidiendo === u.id ? 'Un momento…' : 'Enlace para poner clave' }}
              </button>
              <button
                v-if="u.id !== props.yo.id && props.yo.rol === 'admin'"
                class="boton chico"
                :class="confirmando === u.id ? 'peligro' : 'suave'"
                @click="borra(u)"
              >
                {{ confirmando === u.id ? '¿Seguro?' : 'Quitar' }}
              </button>
            </template>
          </div>
        </td>
      </tr>
    </tbody>
  </table>
</template>
