/// Protocolo del WebSocket hub ↔ agente.
///
/// Versionado desde el día uno porque un agente instalado en la computadora de
/// una nave no se actualiza cuando uno quiere: el hub tendrá que hablar con
/// versiones viejas durante meses. El agente manda su [version] en el `hola`;
/// si el hub deja de entenderla, responde `hola_no` y el agente lo dice claro
/// en su log en vez de quedarse reintentando en silencio.
class Protocolo {
  Protocolo._();

  /// Versión que habla este hub.
  static const int version = 1;

  /// La más vieja que todavía atiende.
  static const int minima = 1;

  // agente → hub
  static const hola = 'hola';
  static const latido = 'latido';
  static const impresoras = 'impresoras';
  static const ack = 'ack';

  // hub → agente
  static const holaOk = 'hola_ok';
  static const holaNo = 'hola_no';
  static const trabajo = 'trabajo';
  static const cancelar = 'cancelar';
}

/// Estados por los que pasa un trabajo. El agente solo puede mover un trabajo
/// a los tres últimos; el resto los pone el hub.
class EstadoTrabajo {
  EstadoTrabajo._();
  static const enCola = 'en_cola';
  static const enviado = 'enviado';
  static const imprimiendo = 'imprimiendo';
  static const hecho = 'hecho';
  static const fallido = 'fallido';
  static const cancelado = 'cancelado';

  static const deAgente = {imprimiendo, hecho, fallido};
}

/// Estados de impresora. `ausente` es «el agente está, la impresora ya no»;
/// `sin_agente` es «la computadora está apagada». La diferencia importa: una
/// se arregla enchufando la impresora, la otra encendiendo la máquina.
class EstadoImpresora {
  EstadoImpresora._();
  static const lista = 'lista';
  static const ocupada = 'ocupada';
  static const pausada = 'pausada';
  static const sinPapel = 'sin_papel';
  static const error = 'error';
  static const ausente = 'ausente';
  static const sinAgente = 'sin_agente';
  static const desconocida = 'desconocida';
}
