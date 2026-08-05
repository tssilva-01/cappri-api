set lock_timeout = '5s';
set statement_timeout = '30s';

alter table public.acessos_roleta
    add column cancelado_em timestamptz;

alter table public.acessos_roleta
    add constraint acessos_roleta_estado_check
        check (cancelado_em is null or utilizado_em is null);

alter table public.participantes
    add column resgatado_em timestamptz,
    add column observacao_resgate text;

alter table public.participantes
    add constraint participantes_observacao_resgate_check
        check (
            observacao_resgate is null
            or char_length(btrim(observacao_resgate)) between 1 and 500
        );

create table public.admin_auditoria (
    id bigint generated always as identity primary key,
    campanha_id integer,
    acao text not null,
    entidade text not null,
    entidade_id integer,
    detalhes jsonb not null default '{}'::jsonb,
    data_criacao timestamptz not null default now(),
    constraint admin_auditoria_campanha_id_fkey
        foreign key (campanha_id) references public.campanhas(id) on delete restrict,
    constraint admin_auditoria_acao_check
        check (char_length(btrim(acao)) between 3 and 80),
    constraint admin_auditoria_entidade_check
        check (entidade in ('campanha', 'premio', 'convite', 'participante')),
    constraint admin_auditoria_detalhes_objeto_check
        check (jsonb_typeof(detalhes) = 'object')
);

alter table public.admin_auditoria enable row level security;

revoke all on table public.admin_auditoria from public, anon, authenticated;
grant all on table public.admin_auditoria to service_role;
grant usage, select on sequence public.admin_auditoria_id_seq to service_role;

create index acessos_roleta_pendentes_campanha_idx
    on public.acessos_roleta (campanha_id, data_criacao desc)
    where utilizado_em is null and cancelado_em is null;

create index participantes_campanha_data_idx
    on public.participantes (campanha_id, data_participacao desc);

create index admin_auditoria_campanha_data_idx
    on public.admin_auditoria (campanha_id, data_criacao desc);

create or replace function public.verificar_token_roleta(p_token text)
returns table (
    valido boolean,
    mensagem text,
    campanha text
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_utilizado_em timestamptz;
    v_cancelado_em timestamptz;
    v_status text;
    v_data_inicio timestamptz;
    v_data_fim timestamptz;
    v_campanha_nome text;
begin
    select a.utilizado_em, a.cancelado_em,
           c.status, c.data_inicio, c.data_fim, c.nome
      into v_utilizado_em, v_cancelado_em,
           v_status, v_data_inicio, v_data_fim, v_campanha_nome
      from public.acessos_roleta as a
      join public.campanhas as c on c.id = a.campanha_id
     where a.token = p_token;

    if not found then
        return query select false, 'Token não existe!', null::text;
    elsif v_cancelado_em is not null then
        return query select false, 'Este convite foi cancelado.', v_campanha_nome;
    elsif v_utilizado_em is not null then
        return query select false, 'Esse link já foi utilizado!', v_campanha_nome;
    elsif v_status <> 'ativa'
       or (v_data_inicio is not null and v_data_inicio > now())
       or (v_data_fim is not null and v_data_fim <= now()) then
        return query select false, 'Esta campanha não está ativa.', v_campanha_nome;
    else
        return query select true, null::text, v_campanha_nome;
    end if;
end;
$$;

drop function public.listar_premios_roleta();

create function public.listar_premios_roleta()
returns table (
    resultado text,
    mensagem text,
    campanha_id integer,
    campanha_nome text,
    texto_consentimento text,
    premio_id integer,
    premio_nome text,
    posicao_roleta integer
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_campanha_id integer;
    v_campanha_nome text;
    v_texto_consentimento text;
begin
    select c.id, c.nome, c.texto_consentimento
      into v_campanha_id, v_campanha_nome, v_texto_consentimento
      from public.campanhas as c
     where c.status = 'ativa'
       and (c.data_inicio is null or c.data_inicio <= now())
       and (c.data_fim is null or c.data_fim > now())
     limit 1;

    if v_campanha_id is null then
        return query
        select 'sem_campanha', 'Não existe uma campanha ativa.',
               null::integer, null::text, null::text,
               null::integer, null::text, null::integer;
        return;
    end if;

    if not exists (
        select 1
          from public.premios as p
         where p.campanha_id = v_campanha_id and p.ativo = true
    ) then
        return query
        select 'sem_premios', 'A campanha não possui prêmios ativos.',
               v_campanha_id, v_campanha_nome, v_texto_consentimento,
               null::integer, null::text, null::integer;
        return;
    end if;

    return query
    select 'sucesso', null::text,
           v_campanha_id, v_campanha_nome, v_texto_consentimento,
           p.id, p.nome,
           row_number() over (order by p.posicao_roleta)::integer
      from public.premios as p
     where p.campanha_id = v_campanha_id
       and p.ativo = true
     order by p.posicao_roleta;
end;
$$;

create or replace function public.sortear_premio_atomico(
    p_token text,
    p_nome text,
    p_whatsapp text,
    p_consentimento boolean
)
returns table (
    resultado text,
    mensagem text,
    premio text,
    indice_roleta integer,
    participante_id integer
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_acesso_id integer;
    v_campanha_id integer;
    v_premio_id integer;
    v_premio_nome text;
    v_total_pesos numeric;
    v_alvo numeric;
    v_acumulado numeric := 0;
    v_participante_id integer;
    v_indice_roleta integer;
    v_premio record;
begin
    if p_token !~ '^[A-Za-z0-9_-]{8,32}$'
       or char_length(btrim(p_nome)) not between 2 and 100
       or p_whatsapp !~ '^[0-9]{10,11}$'
       or p_consentimento is not true then
        raise exception using
            errcode = '22023',
            message = 'Argumentos inválidos para o sorteio.';
    end if;

    select a.id, a.campanha_id
      into v_acesso_id, v_campanha_id
      from public.acessos_roleta as a
      join public.campanhas as c on c.id = a.campanha_id
     where a.token = p_token
       and a.utilizado_em is null
       and a.cancelado_em is null
       and c.status = 'ativa'
       and (c.data_inicio is null or c.data_inicio <= now())
       and (c.data_fim is null or c.data_fim > now())
     for update of a;

    if v_acesso_id is null then
        if exists (
            select 1
              from public.acessos_roleta as a
             where a.token = p_token and a.cancelado_em is not null
        ) then
            return query
            select 'token_cancelado', 'Este convite foi cancelado.', null::text,
                   null::integer, null::integer;
        elsif exists (
            select 1
              from public.acessos_roleta as a
             where a.token = p_token and a.utilizado_em is not null
        ) then
            return query
            select 'token_utilizado', 'Esse link já foi utilizado!', null::text,
                   null::integer, null::integer;
        elsif exists (
            select 1 from public.acessos_roleta as a where a.token = p_token
        ) then
            return query
            select 'campanha_inativa', 'Esta campanha não está ativa.', null::text,
                   null::integer, null::integer;
        else
            return query
            select 'token_invalido', 'Token não existe!', null::text,
                   null::integer, null::integer;
        end if;
        return;
    end if;

    perform p.id
      from public.premios as p
     where p.campanha_id = v_campanha_id
       and p.ativo = true
       and p.estoque_disponivel > 0
       and p.peso_sorteio > 0
     order by p.posicao_roleta
     for update;

    select coalesce(sum(p.peso_sorteio), 0)
      into v_total_pesos
      from public.premios as p
     where p.campanha_id = v_campanha_id
       and p.ativo = true
       and p.estoque_disponivel > 0
       and p.peso_sorteio > 0;

    if v_total_pesos <= 0 then
        return query
        select 'sem_premios', 'Acabaram os prêmios no estoque!', null::text,
               null::integer, null::integer;
        return;
    end if;

    v_alvo := random() * v_total_pesos;

    for v_premio in
        select p.id, p.nome, p.peso_sorteio,
               row_number() over (order by p.posicao_roleta)::integer as indice
          from public.premios as p
         where p.campanha_id = v_campanha_id
           and p.ativo = true
         order by p.posicao_roleta
    loop
        if v_premio.peso_sorteio > 0
           and exists (
               select 1
                 from public.premios as estoque
                where estoque.id = v_premio.id
                  and estoque.estoque_disponivel > 0
           ) then
            v_acumulado := v_acumulado + v_premio.peso_sorteio;
            if v_alvo < v_acumulado then
                v_premio_id := v_premio.id;
                v_premio_nome := v_premio.nome;
                v_indice_roleta := v_premio.indice;
                exit;
            end if;
        end if;
    end loop;

    if v_premio_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'Não foi possível selecionar um prêmio.';
    end if;

    update public.premios
       set estoque_disponivel = estoque_disponivel - 1
     where id = v_premio_id;

    update public.acessos_roleta
       set utilizado_em = clock_timestamp()
     where id = v_acesso_id;

    insert into public.participantes (
        campanha_id,
        nome,
        whatsapp,
        acesso_id,
        premio_id,
        consentimento_em
    )
    values (
        v_campanha_id,
        btrim(p_nome),
        p_whatsapp,
        v_acesso_id,
        v_premio_id,
        clock_timestamp()
    )
    returning id into v_participante_id;

    return query
    select
        'sucesso',
        format('Parabéns %s, você ganhou: %s!', btrim(p_nome), v_premio_nome),
        v_premio_nome,
        v_indice_roleta,
        v_participante_id;
end;
$$;

create function public.obter_painel_admin(p_campanha_id integer default null)
returns table (painel jsonb)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_campanha_id integer;
begin
    if p_campanha_id is not null then
        select c.id into v_campanha_id
          from public.campanhas as c
         where c.id = p_campanha_id;

        if v_campanha_id is null then
            return query select jsonb_build_object(
                'resultado', 'campanha_nao_encontrada'
            );
            return;
        end if;
    else
        select c.id into v_campanha_id
          from public.campanhas as c
         order by (c.status = 'ativa') desc, c.data_criacao desc
         limit 1;
    end if;

    return query
    select jsonb_build_object(
        'resultado', 'sucesso',
        'campanhas', (
            select coalesce(
                jsonb_agg(to_jsonb(lista) order by lista.data_criacao desc),
                '[]'::jsonb
            )
              from (
                  select c.id, c.nome, c.status, c.data_inicio,
                         c.data_fim, c.data_criacao
                    from public.campanhas as c
              ) as lista
        ),
        'campanha', (
            select to_jsonb(selecionada)
              from (
                  select c.id, c.nome, c.status, c.data_inicio, c.data_fim,
                         c.texto_consentimento, c.data_criacao
                    from public.campanhas as c
                   where c.id = v_campanha_id
              ) as selecionada
        ),
        'metricas', jsonb_build_object(
            'convites_total', (
                select count(*) from public.acessos_roleta as a
                 where a.campanha_id = v_campanha_id
            ),
            'convites_pendentes', (
                select count(*) from public.acessos_roleta as a
                 where a.campanha_id = v_campanha_id
                   and a.utilizado_em is null and a.cancelado_em is null
            ),
            'convites_utilizados', (
                select count(*) from public.acessos_roleta as a
                 where a.campanha_id = v_campanha_id
                   and a.utilizado_em is not null
            ),
            'convites_cancelados', (
                select count(*) from public.acessos_roleta as a
                 where a.campanha_id = v_campanha_id
                   and a.cancelado_em is not null
            ),
            'participantes', (
                select count(*) from public.participantes as p
                 where p.campanha_id = v_campanha_id
            ),
            'premios_resgatados', (
                select count(*) from public.participantes as p
                 where p.campanha_id = v_campanha_id
                   and p.resgatado_em is not null
            ),
            'estoque_total', (
                select coalesce(sum(p.estoque_disponivel), 0)
                  from public.premios as p
                 where p.campanha_id = v_campanha_id and p.ativo = true
            )
        ),
        'premios', (
            select coalesce(
                jsonb_agg(to_jsonb(lista) order by lista.posicao_roleta),
                '[]'::jsonb
            )
              from (
                  select p.id, p.nome, p.estoque_disponivel, p.peso_sorteio,
                         p.posicao_roleta, p.ativo,
                         count(pt.id) as quantidade_distribuida,
                         count(pt.id) filter (
                             where pt.resgatado_em is not null
                         ) as quantidade_resgatada
                    from public.premios as p
                    left join public.participantes as pt
                      on pt.premio_id = p.id and pt.campanha_id = p.campanha_id
                   where p.campanha_id = v_campanha_id
                   group by p.id
              ) as lista
        ),
        'participantes', (
            select coalesce(
                jsonb_agg(to_jsonb(lista) order by lista.data_participacao desc),
                '[]'::jsonb
            )
              from (
                  select pt.id,
                         'CPR-' || lpad(pt.id::text, 6, '0') as codigo_voucher,
                         pt.nome, pt.whatsapp, pr.nome as premio,
                         pt.data_participacao, pt.consentimento_em,
                         pt.resgatado_em, pt.observacao_resgate
                    from public.participantes as pt
                    join public.premios as pr on pr.id = pt.premio_id
                   where pt.campanha_id = v_campanha_id
                   order by pt.data_participacao desc
                   limit 200
              ) as lista
        ),
        'convites', (
            select coalesce(
                jsonb_agg(to_jsonb(lista) order by lista.data_criacao desc),
                '[]'::jsonb
            )
              from (
                  select a.id, a.token, a.data_criacao,
                         a.utilizado_em, a.cancelado_em,
                         case
                             when a.cancelado_em is not null then 'cancelado'
                             when a.utilizado_em is not null then 'utilizado'
                             else 'pendente'
                         end as status
                    from public.acessos_roleta as a
                   where a.campanha_id = v_campanha_id
                   order by a.data_criacao desc
                   limit 150
              ) as lista
        ),
        'auditoria', (
            select coalesce(
                jsonb_agg(to_jsonb(lista) order by lista.data_criacao desc),
                '[]'::jsonb
            )
              from (
                  select a.id, a.acao, a.entidade, a.entidade_id,
                         a.detalhes, a.data_criacao
                    from public.admin_auditoria as a
                   where a.campanha_id = v_campanha_id
                   order by a.data_criacao desc
                   limit 100
              ) as lista
        )
    );
end;
$$;

create function public.criar_campanha_admin(
    p_nome text,
    p_data_inicio timestamptz,
    p_data_fim timestamptz,
    p_texto_consentimento text
)
returns table (resultado text, campanha_id integer)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_campanha_id integer;
begin
    insert into public.campanhas (
        nome, status, data_inicio, data_fim, texto_consentimento
    ) values (
        btrim(p_nome), 'rascunho', p_data_inicio, p_data_fim,
        btrim(p_texto_consentimento)
    )
    returning id into v_campanha_id;

    insert into public.admin_auditoria (
        campanha_id, acao, entidade, entidade_id, detalhes
    ) values (
        v_campanha_id, 'Campanha criada', 'campanha', v_campanha_id,
        jsonb_build_object('nome', btrim(p_nome), 'status', 'rascunho')
    );

    return query select 'sucesso', v_campanha_id;
end;
$$;

create function public.atualizar_campanha_admin(
    p_campanha_id integer,
    p_nome text,
    p_status text,
    p_data_inicio timestamptz,
    p_data_fim timestamptz,
    p_texto_consentimento text
)
returns table (resultado text, campanha_id integer)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_status_anterior text;
begin
    select c.status into v_status_anterior
      from public.campanhas as c
     where c.id = p_campanha_id
     for update;

    if not found then
        return query select 'nao_encontrada', null::integer;
        return;
    end if;

    if p_status = 'ativa' then
        if exists (
            select 1 from public.campanhas as c
             where c.status = 'ativa' and c.id <> p_campanha_id
        ) then
            return query select 'outra_campanha_ativa', p_campanha_id;
            return;
        end if;

        if (
            select count(*) from public.premios as p
             where p.campanha_id = p_campanha_id and p.ativo = true
        ) < 2 then
            return query select 'premios_insuficientes', p_campanha_id;
            return;
        end if;
    end if;

    update public.campanhas
       set nome = btrim(p_nome),
           status = p_status,
           data_inicio = p_data_inicio,
           data_fim = p_data_fim,
           texto_consentimento = btrim(p_texto_consentimento)
     where id = p_campanha_id;

    insert into public.admin_auditoria (
        campanha_id, acao, entidade, entidade_id, detalhes
    ) values (
        p_campanha_id, 'Campanha atualizada', 'campanha', p_campanha_id,
        jsonb_build_object(
            'nome', btrim(p_nome),
            'status_anterior', v_status_anterior,
            'status_novo', p_status
        )
    );

    return query select 'sucesso', p_campanha_id;
end;
$$;

create function public.criar_premio_admin(
    p_campanha_id integer,
    p_nome text,
    p_estoque_disponivel integer,
    p_peso_sorteio numeric,
    p_ativo boolean
)
returns table (resultado text, premio_id integer)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_posicao smallint;
    v_premio_id integer;
begin
    perform c.id from public.campanhas as c
     where c.id = p_campanha_id for update;
    if not found then
        return query select 'campanha_nao_encontrada', null::integer;
        return;
    end if;

    select (coalesce(max(p.posicao_roleta), 0) + 1)::smallint
      into v_posicao
      from public.premios as p
     where p.campanha_id = p_campanha_id;

    insert into public.premios (
        campanha_id, nome, estoque_disponivel,
        peso_sorteio, posicao_roleta, ativo
    ) values (
        p_campanha_id, btrim(p_nome), p_estoque_disponivel,
        p_peso_sorteio, v_posicao, p_ativo
    )
    returning id into v_premio_id;

    insert into public.admin_auditoria (
        campanha_id, acao, entidade, entidade_id, detalhes
    ) values (
        p_campanha_id, 'Prêmio criado', 'premio', v_premio_id,
        jsonb_build_object(
            'nome', btrim(p_nome),
            'estoque', p_estoque_disponivel,
            'peso', p_peso_sorteio,
            'ativo', p_ativo
        )
    );

    return query select 'sucesso', v_premio_id;
end;
$$;

create function public.atualizar_premio_admin(
    p_premio_id integer,
    p_nome text,
    p_estoque_disponivel integer,
    p_peso_sorteio numeric,
    p_ativo boolean
)
returns table (resultado text, premio_id integer)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_campanha_id integer;
    v_campanha_status text;
    v_ativo_anterior boolean;
begin
    select p.campanha_id, c.status, p.ativo
      into v_campanha_id, v_campanha_status, v_ativo_anterior
      from public.premios as p
      join public.campanhas as c on c.id = p.campanha_id
     where p.id = p_premio_id
     for update of p;

    if not found then
        return query select 'nao_encontrado', null::integer;
        return;
    end if;

    if v_campanha_status = 'ativa'
       and v_ativo_anterior = true
       and p_ativo = false
       and (
           select count(*) from public.premios as p
            where p.campanha_id = v_campanha_id
              and p.ativo = true and p.id <> p_premio_id
       ) < 2 then
        return query select 'minimo_dois_premios', p_premio_id;
        return;
    end if;

    update public.premios
       set nome = btrim(p_nome),
           estoque_disponivel = p_estoque_disponivel,
           peso_sorteio = p_peso_sorteio,
           ativo = p_ativo
     where id = p_premio_id;

    insert into public.admin_auditoria (
        campanha_id, acao, entidade, entidade_id, detalhes
    ) values (
        v_campanha_id, 'Prêmio atualizado', 'premio', p_premio_id,
        jsonb_build_object(
            'nome', btrim(p_nome),
            'estoque', p_estoque_disponivel,
            'peso', p_peso_sorteio,
            'ativo', p_ativo
        )
    );

    return query select 'sucesso', p_premio_id;
end;
$$;

create function public.cancelar_convite_admin(p_acesso_id integer)
returns table (resultado text, convite_id integer)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_campanha_id integer;
    v_utilizado_em timestamptz;
    v_cancelado_em timestamptz;
begin
    select a.campanha_id, a.utilizado_em, a.cancelado_em
      into v_campanha_id, v_utilizado_em, v_cancelado_em
      from public.acessos_roleta as a
     where a.id = p_acesso_id
     for update;

    if not found then
        return query select 'nao_encontrado', null::integer;
        return;
    elsif v_utilizado_em is not null then
        return query select 'ja_utilizado', p_acesso_id;
        return;
    elsif v_cancelado_em is not null then
        return query select 'ja_cancelado', p_acesso_id;
        return;
    end if;

    update public.acessos_roleta
       set cancelado_em = clock_timestamp()
     where id = p_acesso_id;

    insert into public.admin_auditoria (
        campanha_id, acao, entidade, entidade_id
    ) values (
        v_campanha_id, 'Convite cancelado', 'convite', p_acesso_id
    );

    return query select 'sucesso', p_acesso_id;
end;
$$;

create function public.atualizar_resgate_admin(
    p_participante_id integer,
    p_resgatado boolean,
    p_observacao text
)
returns table (resultado text, participante_id integer)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_campanha_id integer;
begin
    select p.campanha_id into v_campanha_id
      from public.participantes as p
     where p.id = p_participante_id
     for update;

    if not found then
        return query select 'nao_encontrado', null::integer;
        return;
    end if;

    update public.participantes
       set resgatado_em = case
               when p_resgatado then coalesce(resgatado_em, clock_timestamp())
               else null
           end,
           observacao_resgate = nullif(btrim(p_observacao), '')
     where id = p_participante_id;

    insert into public.admin_auditoria (
        campanha_id, acao, entidade, entidade_id, detalhes
    ) values (
        v_campanha_id,
        case when p_resgatado then 'Prêmio resgatado' else 'Resgate desfeito' end,
        'participante', p_participante_id,
        jsonb_build_object('resgatado', p_resgatado)
    );

    return query select 'sucesso', p_participante_id;
end;
$$;

create function public.listar_participantes_admin(p_campanha_id integer)
returns table (
    codigo_voucher text,
    nome text,
    whatsapp text,
    premio text,
    data_participacao timestamptz,
    resgatado_em timestamptz,
    observacao_resgate text
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
    select 'CPR-' || lpad(pt.id::text, 6, '0'),
           pt.nome, pt.whatsapp, pr.nome,
           pt.data_participacao, pt.resgatado_em, pt.observacao_resgate
      from public.participantes as pt
      join public.premios as pr on pr.id = pt.premio_id
     where pt.campanha_id = p_campanha_id
     order by pt.data_participacao desc;
$$;

revoke all on function public.verificar_token_roleta(text)
from public, anon, authenticated;
revoke all on function public.listar_premios_roleta()
from public, anon, authenticated;
revoke all on function public.sortear_premio_atomico(text, text, text, boolean)
from public, anon, authenticated;
revoke all on function public.obter_painel_admin(integer)
from public, anon, authenticated;
revoke all on function public.criar_campanha_admin(text, timestamptz, timestamptz, text)
from public, anon, authenticated;
revoke all on function public.atualizar_campanha_admin(integer, text, text, timestamptz, timestamptz, text)
from public, anon, authenticated;
revoke all on function public.criar_premio_admin(integer, text, integer, numeric, boolean)
from public, anon, authenticated;
revoke all on function public.atualizar_premio_admin(integer, text, integer, numeric, boolean)
from public, anon, authenticated;
revoke all on function public.cancelar_convite_admin(integer)
from public, anon, authenticated;
revoke all on function public.atualizar_resgate_admin(integer, boolean, text)
from public, anon, authenticated;
revoke all on function public.listar_participantes_admin(integer)
from public, anon, authenticated;

grant execute on function public.verificar_token_roleta(text) to service_role;
grant execute on function public.listar_premios_roleta() to service_role;
grant execute on function public.sortear_premio_atomico(text, text, text, boolean)
to service_role;
grant execute on function public.obter_painel_admin(integer) to service_role;
grant execute on function public.criar_campanha_admin(text, timestamptz, timestamptz, text)
to service_role;
grant execute on function public.atualizar_campanha_admin(integer, text, text, timestamptz, timestamptz, text)
to service_role;
grant execute on function public.criar_premio_admin(integer, text, integer, numeric, boolean)
to service_role;
grant execute on function public.atualizar_premio_admin(integer, text, integer, numeric, boolean)
to service_role;
grant execute on function public.cancelar_convite_admin(integer) to service_role;
grant execute on function public.atualizar_resgate_admin(integer, boolean, text)
to service_role;
grant execute on function public.listar_participantes_admin(integer)
to service_role;

comment on column public.acessos_roleta.cancelado_em is
'Data em que um convite ainda não utilizado foi invalidado pela administração.';
comment on column public.participantes.resgatado_em is
'Data em que a equipe confirmou a entrega ou utilização do prêmio.';
comment on table public.admin_auditoria is
'Histórico operacional das alterações feitas pela área administrativa.';
