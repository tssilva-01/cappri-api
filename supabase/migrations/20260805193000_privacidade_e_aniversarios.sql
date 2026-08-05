set lock_timeout = '5s';
set statement_timeout = '30s';

alter table public.campanhas
    add column politica_privacidade_versao text not null default '1.0';

alter table public.campanhas
    add constraint campanhas_politica_privacidade_versao_check
        check (char_length(btrim(politica_privacidade_versao)) between 1 and 20);

alter table public.participantes
    add column politica_privacidade_versao text not null default '1.0',
    add column texto_ciencia_privacidade text not null default
        'Li o Aviso de Privacidade e estou ciente de como meus dados serão utilizados nesta campanha.',
    add column data_nascimento date,
    add column consentimento_aniversario_em timestamptz,
    add column consentimento_aniversario_revogado_em timestamptz;

update public.campanhas
   set texto_consentimento =
       'Li o Aviso de Privacidade e estou ciente de como meus dados serão utilizados nesta campanha.';

update public.participantes as pt
   set politica_privacidade_versao = c.politica_privacidade_versao,
       texto_ciencia_privacidade = c.texto_consentimento
  from public.campanhas as c
 where c.id = pt.campanha_id;

alter table public.participantes
    add constraint participantes_politica_privacidade_versao_check
        check (char_length(btrim(politica_privacidade_versao)) between 1 and 20),
    add constraint participantes_texto_ciencia_privacidade_check
        check (char_length(btrim(texto_ciencia_privacidade)) between 10 and 500),
    add constraint participantes_aniversario_estado_check
        check (
            (
                data_nascimento is null
                and consentimento_aniversario_em is null
                and consentimento_aniversario_revogado_em is null
            )
            or (
                data_nascimento is not null
                and consentimento_aniversario_em is not null
                and consentimento_aniversario_revogado_em is null
            )
            or (
                data_nascimento is null
                and consentimento_aniversario_em is not null
                and consentimento_aniversario_revogado_em is not null
                and consentimento_aniversario_revogado_em
                    >= consentimento_aniversario_em
            )
        ),
    add constraint participantes_aniversario_maioridade_check
        check (
            data_nascimento is null
            or data_nascimento <= (
                (data_participacao at time zone 'America/Sao_Paulo')::date
                - interval '18 years'
            )::date
        );

drop function public.listar_premios_roleta();

create function public.listar_premios_roleta()
returns table (
    resultado text,
    mensagem text,
    campanha_id integer,
    campanha_nome text,
    texto_consentimento text,
    politica_privacidade_versao text,
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
    v_politica_privacidade_versao text;
begin
    select c.id, c.nome, c.texto_consentimento,
           c.politica_privacidade_versao
      into v_campanha_id, v_campanha_nome, v_texto_consentimento,
           v_politica_privacidade_versao
      from public.campanhas as c
     where c.status = 'ativa'
       and (c.data_inicio is null or c.data_inicio <= now())
       and (c.data_fim is null or c.data_fim > now())
     limit 1;

    if v_campanha_id is null then
        return query
        select 'sem_campanha', 'Não existe uma campanha ativa.',
               null::integer, null::text, null::text, null::text,
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
               v_politica_privacidade_versao,
               null::integer, null::text, null::integer;
        return;
    end if;

    return query
    select 'sucesso', null::text,
           v_campanha_id, v_campanha_nome, v_texto_consentimento,
           v_politica_privacidade_versao,
           p.id, p.nome,
           row_number() over (order by p.posicao_roleta)::integer
      from public.premios as p
     where p.campanha_id = v_campanha_id
       and p.ativo = true
     order by p.posicao_roleta;
end;
$$;

create function public.sortear_premio_com_privacidade(
    p_token text,
    p_nome text,
    p_whatsapp text,
    p_ciencia_privacidade boolean,
    p_data_nascimento date,
    p_consentimento_aniversario boolean
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
    v_texto_ciencia_privacidade text;
    v_politica_privacidade_versao text;
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
       or p_ciencia_privacidade is not true
       or p_consentimento_aniversario is null
       or (p_consentimento_aniversario and p_data_nascimento is null)
       or (not p_consentimento_aniversario and p_data_nascimento is not null)
       or (
           p_data_nascimento is not null
           and p_data_nascimento > (current_date - interval '18 years')::date
       ) then
        raise exception using
            errcode = '22023',
            message = 'Argumentos inválidos para o sorteio.';
    end if;

    select a.id, a.campanha_id, c.texto_consentimento,
           c.politica_privacidade_versao
      into v_acesso_id, v_campanha_id, v_texto_ciencia_privacidade,
           v_politica_privacidade_versao
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
        consentimento_em,
        politica_privacidade_versao,
        texto_ciencia_privacidade,
        data_nascimento,
        consentimento_aniversario_em
    )
    values (
        v_campanha_id,
        btrim(p_nome),
        p_whatsapp,
        v_acesso_id,
        v_premio_id,
        clock_timestamp(),
        v_politica_privacidade_versao,
        v_texto_ciencia_privacidade,
        p_data_nascimento,
        case when p_consentimento_aniversario
             then clock_timestamp() else null end
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

create or replace function public.obter_painel_admin(
    p_campanha_id integer default null
)
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
                         c.texto_consentimento,
                         c.politica_privacidade_versao, c.data_criacao
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
            'aniversarios_ativos', (
                select count(*) from public.participantes as p
                 where p.campanha_id = v_campanha_id
                   and p.data_nascimento is not null
                   and p.consentimento_aniversario_em is not null
                   and p.consentimento_aniversario_revogado_em is null
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
                         pt.politica_privacidade_versao,
                         pt.data_nascimento,
                         pt.consentimento_aniversario_em,
                         pt.consentimento_aniversario_revogado_em,
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

create function public.revogar_consentimento_aniversario_admin(
    p_participante_id integer
)
returns table (resultado text, participante_id integer)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_campanha_id integer;
    v_consentimento_em timestamptz;
    v_revogado_em timestamptz;
begin
    select p.campanha_id, p.consentimento_aniversario_em,
           p.consentimento_aniversario_revogado_em
      into v_campanha_id, v_consentimento_em, v_revogado_em
      from public.participantes as p
     where p.id = p_participante_id
     for update;

    if not found then
        return query select 'nao_encontrado', null::integer;
        return;
    elsif v_consentimento_em is null then
        return query select 'nao_autorizado', p_participante_id;
        return;
    elsif v_revogado_em is not null then
        return query select 'ja_revogado', p_participante_id;
        return;
    end if;

    update public.participantes
       set data_nascimento = null,
           consentimento_aniversario_revogado_em = clock_timestamp()
     where id = p_participante_id;

    insert into public.admin_auditoria (
        campanha_id, acao, entidade, entidade_id
    ) values (
        v_campanha_id, 'Consentimento de aniversário revogado',
        'participante', p_participante_id
    );

    return query select 'sucesso', p_participante_id;
end;
$$;

drop function public.listar_participantes_admin(integer);

create function public.listar_participantes_admin(p_campanha_id integer)
returns table (
    codigo_voucher text,
    nome text,
    whatsapp text,
    premio text,
    data_nascimento date,
    consentimento_aniversario_em timestamptz,
    consentimento_aniversario_revogado_em timestamptz,
    politica_privacidade_versao text,
    ciencia_privacidade_em timestamptz,
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
           pt.data_nascimento, pt.consentimento_aniversario_em,
           pt.consentimento_aniversario_revogado_em,
           pt.politica_privacidade_versao, pt.consentimento_em,
           pt.data_participacao, pt.resgatado_em, pt.observacao_resgate
      from public.participantes as pt
      join public.premios as pr on pr.id = pt.premio_id
     where pt.campanha_id = p_campanha_id
     order by pt.data_participacao desc;
$$;

revoke all on function public.listar_premios_roleta()
from public, anon, authenticated;
revoke all on function public.sortear_premio_com_privacidade(
    text, text, text, boolean, date, boolean
)
from public, anon, authenticated;
revoke all on function public.obter_painel_admin(integer)
from public, anon, authenticated;
revoke all on function public.revogar_consentimento_aniversario_admin(integer)
from public, anon, authenticated;
revoke all on function public.listar_participantes_admin(integer)
from public, anon, authenticated;

grant execute on function public.listar_premios_roleta() to service_role;
grant execute on function public.sortear_premio_com_privacidade(
    text, text, text, boolean, date, boolean
) to service_role;
grant execute on function public.obter_painel_admin(integer) to service_role;
grant execute on function public.revogar_consentimento_aniversario_admin(integer)
to service_role;
grant execute on function public.listar_participantes_admin(integer)
to service_role;

comment on column public.campanhas.politica_privacidade_versao is
'Versão do aviso de privacidade apresentada às participantes da campanha.';
comment on column public.participantes.consentimento_em is
'Momento em que a participante declarou ciência do aviso de privacidade.';
comment on column public.participantes.texto_ciencia_privacidade is
'Cópia do texto de ciência exibido no momento da participação.';
comment on column public.participantes.data_nascimento is
'Data opcional, armazenada somente durante autorização ativa para mensagem de aniversário.';
comment on column public.participantes.consentimento_aniversario_em is
'Momento da autorização opcional para mensagem de aniversário via WhatsApp.';
comment on column public.participantes.consentimento_aniversario_revogado_em is
'Momento da revogação; nessa operação a data de nascimento é removida.';
