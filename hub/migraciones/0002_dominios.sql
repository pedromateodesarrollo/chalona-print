-- Dominios: agrupan agentes, llaves y trabajos dentro de una organización.
--
-- Un dominio es «dónde ocurre esto»: una sucursal, un almacén, un cliente al
-- que se le da servicio. Sirve para que una llave de API entregada a la
-- sucursal de Santiago pueda instalar agentes y mandar a imprimir **ahí y solo
-- ahí**, aunque la organización tenga otras diez.
--
-- Toda organización tiene al menos uno. Quien no necesite la separación se
-- queda con «General» y no se entera de que existe.

create table if not exists print.dominio (
  id          bigserial primary key,
  org         bigint      not null references print.org(id) on delete cascade,
  nombre      text        not null,
  slug        text        not null,
  descripcion text        not null default '',
  creado      timestamptz not null default now(),
  unique (org, slug)
);

-- El agente pertenece al dominio de la llave con la que se instaló.
alter table print.agente
  add column if not exists dominio bigint references print.dominio(id) on delete set null;

-- Una llave SIN dominio alcanza toda la organización; con dominio, solo ese.
-- Es la diferencia entre la llave del sistema central y la que se le manda a
-- una sucursal por correo.
alter table print.llave
  add column if not exists dominio bigint references print.dominio(id) on delete set null;

-- Impresora y trabajo lo llevan copiado del agente. Se desnormaliza a
-- propósito: el filtro por dominio entra en cada listado y en cada envío, y
-- con la copia es un índice en vez de un join en el camino caliente.
alter table print.impresora
  add column if not exists dominio bigint references print.dominio(id) on delete set null;
alter table print.trabajo
  add column if not exists dominio bigint references print.dominio(id) on delete set null;

create index if not exists agente_dominio_idx on print.agente (dominio);
create index if not exists impresora_dominio_idx on print.impresora (dominio);
create index if not exists trabajo_dominio_idx on print.trabajo (dominio);

-- Las organizaciones que ya existían se quedan con un dominio «General» y
-- todo dentro. Sin esto, lo de antes quedaría fuera de todo dominio y una
-- llave acotada no vería nada.
insert into print.dominio (org, nombre, slug)
select id, 'General', 'general' from print.org
on conflict (org, slug) do nothing;

update print.agente a
   set dominio = d.id
  from print.dominio d
 where d.org = a.org and d.slug = 'general' and a.dominio is null;

update print.impresora i
   set dominio = a.dominio
  from print.agente a
 where a.id = i.agente and i.dominio is null;

update print.trabajo t
   set dominio = i.dominio
  from print.impresora i
 where i.id = t.impresora and t.dominio is null;
