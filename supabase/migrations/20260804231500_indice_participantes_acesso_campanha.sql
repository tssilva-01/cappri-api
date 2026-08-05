-- Índice que cobre a chave estrangeira composta entre participantes e acessos.
-- Ele acelera as verificações e exclusões relacionadas a um acesso da campanha.
create index if not exists participantes_acesso_campanha_idx
    on public.participantes (acesso_id, campanha_id);
