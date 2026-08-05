-- Regrava as funções com texto UTF-8 correto.
-- A primeira aplicação foi lida com a codificação padrão do PowerShell 5.1.
create or replace function public.gerar_convite_roleta(p_token text)
returns table (
    resultado text,
    mensagem text,
    token_gerado text,
    campanha text
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_campanha_id integer;
    v_campanha_nome text;
begin
    if p_token !~ '^[A-Za-z0-9_-]{8,32}$' then
        raise exception using
            errcode = '22023',
            message = 'Formato de token inválido.';
    end if;

    select c.id, c.nome
      into v_campanha_id, v_campanha_nome
      from public.campanhas as c
     where c.status = 'ativa'
       and (c.data_inicio is null or c.data_inicio <= now())
       and (c.data_fim is null or c.data_fim > now())
     limit 1;

    if v_campanha_id is null then
        return query
        select 'sem_campanha', 'Não existe uma campanha ativa.', null::text, null::text;
        return;
    end if;

    insert into public.acessos_roleta (campanha_id, token)
    values (v_campanha_id, p_token);

    return query
    select 'sucesso', null::text, p_token, v_campanha_nome;
end;
$$;

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
    v_status text;
    v_data_inicio timestamptz;
    v_data_fim timestamptz;
    v_campanha_nome text;
begin
    select a.utilizado_em, c.status, c.data_inicio, c.data_fim, c.nome
      into v_utilizado_em, v_status, v_data_inicio, v_data_fim, v_campanha_nome
      from public.acessos_roleta as a
      join public.campanhas as c on c.id = a.campanha_id
     where a.token = p_token;

    if not found then
        return query select false, 'Token não existe!', null::text;
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

create or replace function public.listar_premios_roleta()
returns table (
    resultado text,
    mensagem text,
    campanha_id integer,
    campanha_nome text,
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
begin
    select c.id, c.nome
      into v_campanha_id, v_campanha_nome
      from public.campanhas as c
     where c.status = 'ativa'
       and (c.data_inicio is null or c.data_inicio <= now())
       and (c.data_fim is null or c.data_fim > now())
     limit 1;

    if v_campanha_id is null then
        return query
        select 'sem_campanha', 'Não existe uma campanha ativa.',
               null::integer, null::text, null::integer, null::text, null::integer;
        return;
    end if;

    if not exists (
        select 1 from public.premios as p where p.campanha_id = v_campanha_id
    ) then
        return query
        select 'sem_premios', 'A campanha não possui prêmios.',
               v_campanha_id, v_campanha_nome,
               null::integer, null::text, null::integer;
        return;
    end if;

    return query
    select 'sucesso', null::text, v_campanha_id, v_campanha_nome,
           p.id, p.nome, p.posicao_roleta::integer
      from public.premios as p
     where p.campanha_id = v_campanha_id
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
       and c.status = 'ativa'
       and (c.data_inicio is null or c.data_inicio <= now())
       and (c.data_fim is null or c.data_fim > now())
     for update of a;

    if v_acesso_id is null then
        if exists (
            select 1
              from public.acessos_roleta as a
             where a.token = p_token
               and a.utilizado_em is not null
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
        select p.id, p.nome, p.peso_sorteio, p.posicao_roleta
          from public.premios as p
         where p.campanha_id = v_campanha_id
           and p.ativo = true
           and p.estoque_disponivel > 0
           and p.peso_sorteio > 0
         order by p.posicao_roleta
    loop
        v_acumulado := v_acumulado + v_premio.peso_sorteio;
        if v_alvo < v_acumulado then
            v_premio_id := v_premio.id;
            v_premio_nome := v_premio.nome;
            v_indice_roleta := v_premio.posicao_roleta;
            exit;
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

comment on table public.campanhas is
'Controla campanhas independentes, seus períodos e o texto de consentimento.';

comment on column public.premios.peso_sorteio is
'Peso relativo do prêmio; não representa uma porcentagem direta.';

comment on column public.premios.posicao_roleta is
'Posição visual única do prêmio dentro da campanha.';

comment on function public.sortear_premio_atomico(text, text, text, boolean) is
'Realiza consumo do token, baixa de estoque, consentimento e cadastro do participante em uma única transação.';

