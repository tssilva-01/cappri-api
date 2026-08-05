create or replace function public.sortear_premio_atomico(
    p_token text,
    p_nome text,
    p_whatsapp text
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
       or p_whatsapp !~ '^\d{10,11}$' then
        raise exception using
            errcode = '22023',
            message = 'Argumentos inválidos para o sorteio.';
    end if;

    -- O FOR UPDATE impede dois sorteios simultâneos com o mesmo token.
    select a.id
      into v_acesso_id
      from public.acessos_roleta as a
     where a.token = p_token
       and a.utilizado = false
     for update;

    if v_acesso_id is null then
        if exists (
            select 1
              from public.acessos_roleta as a
             where a.token = p_token
               and a.utilizado = true
        ) then
            return query
            select 'token_utilizado', 'Esse link já foi utilizado!', null::text,
                   null::integer, null::integer;
        else
            return query
            select 'token_invalido', 'Token não existe!', null::text,
                   null::integer, null::integer;
        end if;
        return;
    end if;

    -- Bloqueia os prêmios elegíveis enquanto escolhe e desconta o estoque.
    perform p.id
      from public.premios as p
     where p.quantidade_estoque > 0
       and coalesce(p.probabilidade, 0) > 0
     order by p.id
     for update;

    select coalesce(sum(p.probabilidade), 0)
      into v_total_pesos
      from public.premios as p
     where p.quantidade_estoque > 0
       and coalesce(p.probabilidade, 0) > 0;

    if v_total_pesos <= 0 then
        return query
        select 'sem_premios', 'Acabaram os prêmios no estoque!', null::text,
               null::integer, null::integer;
        return;
    end if;

    v_alvo := random() * v_total_pesos;

    for v_premio in
        select p.id, p.nome, p.probabilidade
          from public.premios as p
         where p.quantidade_estoque > 0
           and coalesce(p.probabilidade, 0) > 0
         order by p.id
    loop
        v_acumulado := v_acumulado + v_premio.probabilidade;
        if v_alvo < v_acumulado then
            v_premio_id := v_premio.id;
            v_premio_nome := v_premio.nome;
            exit;
        end if;
    end loop;

    if v_premio_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'Não foi possível selecionar um prêmio.';
    end if;

    update public.premios
       set quantidade_estoque = quantidade_estoque - 1
     where id = v_premio_id;

    update public.acessos_roleta
       set utilizado = true
     where id = v_acesso_id;

    insert into public.participantes (nome, whatsapp, acesso_id, premio_id)
    values (p_nome, p_whatsapp, v_acesso_id, v_premio_id)
    returning id into v_participante_id;

    select count(*)::integer
      into v_indice_roleta
      from public.premios as p
     where p.id <= v_premio_id;

    return query
    select
        'sucesso',
        format('Parabéns %s, você ganhou: %s!', p_nome, v_premio_nome),
        v_premio_nome,
        v_indice_roleta,
        v_participante_id;
end;
$$;

revoke all on function public.sortear_premio_atomico(text, text, text)
from public, anon, authenticated;

grant execute on function public.sortear_premio_atomico(text, text, text)
to service_role;

comment on function public.sortear_premio_atomico(text, text, text) is
'Realiza consumo do token, baixa de estoque e cadastro do participante em uma única transação.';
