-- chalona-print — esquema inicial.
--
-- Todo vive en el esquema `print` para que el hub pueda compartir base de
-- datos con otra aplicación sin pisarle las tablas. Nada aquí depende de
-- Chalona: quien clone el repo levanta este archivo en un Postgres vacío y ya.
--
-- El aislamiento entre organizaciones lo aplica el código (toda consulta
-- filtra por `org`). No hay RLS a propósito: el hub conecta con un solo rol y
-- una política por fila obligaría a fijar un GUC por petición sin ganar nada
-- que el filtro explícito no dé ya.

create schema if not exists print;

-- Una organización es el inquilino. En una instalación de un solo dueño
-- habrá exactamente una y nadie la nota.
create table if not exists print.org (
  id          bigserial primary key,
  nombre      text        not null,
  slug        text        not null unique,
  creado      timestamptz not null default now()
);

-- Un usuario pertenece a una sola organización. El correo es único global:
-- si algún día alguien tiene que estar en dos, se resuelve con una tabla de
-- membresías, no ensuciando esta.
create table if not exists print.usuario (
  id            bigserial primary key,
  org           bigint      not null references print.org(id) on delete cascade,
  correo        text        not null unique,
  clave_hash    text        not null,
  nombre        text        not null default '',
  rol           text        not null default 'admin' check (rol in ('admin', 'operador')),
  verificado    boolean     not null default false,
  verificacion  text,
  creado        timestamptz not null default now(),
  ultimo_acceso timestamptz
);

-- El servicio instalado en una computadora con impresoras.
--
-- Para instalar solo hacen falta dos cosas: la URL del hub y una llave de API.
-- Con esa llave el agente se da de alta solo y recibe su `credencial_hash`,
-- que es lo que usa a partir de entonces para abrir el WebSocket.
--
-- ¿Por qué no usar la llave de API directamente en el WebSocket? Porque la
-- llave es una sola para toda la organización: con ella no se distingue una
-- computadora de otra, y revocarla al jubilar una máquina dejaría mudas a
-- todas. La credencial por agente da identidad y revocación individual sin que
-- nadie tenga que teclear una segunda cosa.
--
-- `huella` identifica la máquina entre reinstalaciones, para que reinstalar el
-- servicio no llene la lista de agentes duplicados.
create table if not exists print.agente (
  id                   bigserial primary key,
  org                  bigint      not null references print.org(id) on delete cascade,
  nombre               text        not null,
  huella               text,
  credencial_hash      text,
  version              text        not null default '',
  plataforma           text        not null default '',
  conectado            boolean     not null default false,
  ultima_conexion      timestamptz,
  ultima_desconexion   timestamptz,
  creado               timestamptz not null default now()
);
create index if not exists agente_org_idx on print.agente (org);
create unique index if not exists agente_huella_uk
  on print.agente (org, huella) where huella is not null;

-- Una impresora la descubre el agente en el spooler del sistema operativo.
-- `sistema` es el nombre que le da el SO (la llave real); `nombre` es el que
-- se le pone para la gente y se puede cambiar sin romper nada.
create table if not exists print.impresora (
  id             bigserial primary key,
  org            bigint      not null references print.org(id) on delete cascade,
  agente         bigint      not null references print.agente(id) on delete cascade,
  sistema        text        not null,
  nombre         text        not null,
  estado         text        not null default 'desconocida',
  detalle        text        not null default '',
  cola           integer     not null default 0,
  predeterminada boolean     not null default false,
  formatos       text[]      not null default '{}',
  visto          timestamptz,
  creado         timestamptz not null default now(),
  unique (agente, sistema)
);
create index if not exists impresora_org_idx on print.impresora (org);

-- Un trabajo de impresión. El contenido va en la base porque una etiqueta
-- pesa kilobytes y así el trabajo sobrevive a un reinicio del hub; el tamaño
-- máximo lo acota la configuración, no la tabla.
create table if not exists print.trabajo (
  id            bigserial primary key,
  org           bigint      not null references print.org(id) on delete cascade,
  impresora     bigint      references print.impresora(id) on delete set null,
  agente        bigint      references print.agente(id) on delete set null,
  formato       text        not null check (formato in ('raw', 'pdf', 'imagen', 'texto')),
  nombre        text        not null default '',
  contenido     bytea       not null,
  copias        integer     not null default 1 check (copias between 1 and 999),
  opciones      jsonb       not null default '{}'::jsonb,
  estado        text        not null default 'en_cola'
                check (estado in ('en_cola', 'enviado', 'imprimiendo', 'hecho', 'fallido', 'cancelado')),
  detalle       text        not null default '',
  idempotencia  text,
  intentos      integer     not null default 0,
  origen        text        not null default '',
  creado        timestamptz not null default now(),
  actualizado   timestamptz not null default now(),
  enviado       timestamptz,
  terminado     timestamptz,
  expira        timestamptz not null default now() + interval '24 hours'
);
-- La llave de idempotencia es lo que impide que un reintento del cliente
-- imprima dos veces. Parcial porque la mayoría de los trabajos no la traen.
create unique index if not exists trabajo_idempotencia_uk
  on print.trabajo (org, idempotencia) where idempotencia is not null;
create index if not exists trabajo_pendiente_idx
  on print.trabajo (agente, estado) where estado in ('en_cola', 'enviado');
create index if not exists trabajo_org_creado_idx on print.trabajo (org, creado desc);

-- Llave de API para las aplicaciones que imprimen (el WMS, un ERP ajeno).
-- Se guarda el hash; el secreto se enseña una sola vez al crearla.
create table if not exists print.llave (
  id          bigserial primary key,
  org         bigint      not null references print.org(id) on delete cascade,
  nombre      text        not null,
  prefijo     text        not null,
  clave_hash  text        not null,
  permisos    text[]      not null default '{trabajos:escribir,impresoras:leer,agentes:registrar}',
  creado      timestamptz not null default now(),
  ultimo_uso  timestamptz,
  revocada    timestamptz
);
create index if not exists llave_prefijo_idx on print.llave (prefijo);

-- Rastro de lo que le pasó a un trabajo. Sin esto, «no imprimió» es una
-- discusión; con esto es una línea con hora y motivo.
create table if not exists print.evento (
  id       bigserial primary key,
  org      bigint      not null references print.org(id) on delete cascade,
  trabajo  bigint      references print.trabajo(id) on delete cascade,
  agente   bigint      references print.agente(id) on delete set null,
  tipo     text        not null,
  detalle  text        not null default '',
  creado   timestamptz not null default now()
);
create index if not exists evento_trabajo_idx on print.evento (trabajo, creado);
