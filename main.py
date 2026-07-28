import os
import re
import random
import secrets
from collections import defaultdict
from time import time

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, field_validator
from supabase import create_client, Client

# =========================================================
# 1. CONEXÃO COM O BANCO DE DADOS (via variáveis de ambiente)
# =========================================================
# IMPORTANTE: a URL e a CHAVE do Supabase não ficam mais escritas
# aqui no código. Elas são lidas do ambiente do servidor (Render).
# Veja o guia de implementação para saber como cadastrar essas
# variáveis no painel do Render (SUPABASE_URL e SUPABASE_KEY).
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY")

if not SUPABASE_URL or not SUPABASE_KEY:
    raise RuntimeError(
        "As variáveis de ambiente SUPABASE_URL e SUPABASE_KEY não foram "
        "encontradas. Configure-as no painel do Render antes de rodar a API."
    )

supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

app = FastAPI()

# =========================================================
# 2. CORS — só o domínio oficial da loja pode chamar essa API
# =========================================================
# Se no futuro a loja passar a usar um domínio próprio
# (ex: roleta.cappri.com.br), basta adicionar essa nova URL
# nesta lista, mantendo a antiga se ainda estiver em uso.
ORIGENS_PERMITIDAS = [
    "https://capprimodafeminina.github.io",
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=ORIGENS_PERMITIDAS,
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# =========================================================
# 3. VALIDAÇÃO DOS DADOS QUE CHEGAM DO FORMULÁRIO
# =========================================================
class ParticipanteInput(BaseModel):
    nome: str
    whatsapp: str

    @field_validator("nome")
    @classmethod
    def validar_nome(cls, valor: str) -> str:
        valor = valor.strip()
        if len(valor) < 2 or len(valor) > 100:
            raise ValueError("Digite um nome válido.")
        return valor

    @field_validator("whatsapp")
    @classmethod
    def validar_whatsapp(cls, valor: str) -> str:
        # Remove tudo que não for número (parênteses, espaço, traço, etc.)
        somente_numeros = re.sub(r"\D", "", valor)
        if not re.match(r"^\d{10,11}$", somente_numeros):
            raise ValueError(
                "WhatsApp inválido. Use o formato (DD) 9XXXX-XXXX, com DDD."
            )
        return somente_numeros


# Transforma qualquer erro de validação (nome vazio, whatsapp errado, etc.)
# numa resposta simples e única, sempre no campo "detail", para o
# front-end não precisar tratar formatos diferentes de erro.
@app.exception_handler(RequestValidationError)
async def tratar_erro_de_validacao(request: Request, exc: RequestValidationError):
    erros = exc.errors()
    mensagem = erros[0]["msg"] if erros else "Dados inválidos."
    mensagem = mensagem.replace("Value error, ", "")
    return JSONResponse(status_code=422, content={"detail": mensagem})


# =========================================================
# 4. LIMITE DE TENTATIVAS (proteção simples contra abuso)
# =========================================================
# Guarda, na memória do servidor, os horários das últimas tentativas
# de cada IP. Não é uma solução robusta de nível bancário, mas evita
# que alguém fique tentando "adivinhar" tokens em sequência rápida.
_tentativas_por_ip = defaultdict(list)
JANELA_SEGUNDOS = 60
LIMITE_TENTATIVAS = 5


def verificar_limite_de_tentativas(request: Request):
    ip = request.client.host if request.client else "desconhecido"
    agora = time()
    tentativas = _tentativas_por_ip[ip]
    tentativas[:] = [t for t in tentativas if agora - t < JANELA_SEGUNDOS]
    if len(tentativas) >= LIMITE_TENTATIVAS:
        raise HTTPException(
            status_code=429,
            detail="Muitas tentativas em pouco tempo. Aguarde um minuto e tente novamente.",
        )
    tentativas.append(agora)


# =========================================================
# ROTAS
# =========================================================
@app.get("/ping")
def ping():
    # Endpoint propositalmente simples: não consulta o Supabase, só
    # confirma que o servidor está de pé. Existe só pra ser chamado
    # periodicamente e evitar que a hospedagem gratuita "durma".
    return {"status": "acordado"}


class GerarConviteInput(BaseModel):
    senha: str


@app.post("/gerar-convite")
def gerar_convite(dados: GerarConviteInput, request: Request):
    # Reaproveita o mesmo limite de tentativas do sorteio — aqui ele
    # serve pra impedir que alguém fique tentando adivinhar a senha
    # repetidamente em pouco tempo.
    verificar_limite_de_tentativas(request)

    senha_correta = os.environ.get("SENHA_FUNCIONARIA")
    if not senha_correta:
        raise HTTPException(
            status_code=500,
            detail="Senha da equipe não configurada no servidor.",
        )
    if dados.senha != senha_correta:
        raise HTTPException(status_code=401, detail="Senha incorreta.")

    # Token curto, mas com bastante aleatoriedade — não dá pra adivinhar
    # tentando números em sequência.
    novo_token = secrets.token_urlsafe(6)

    supabase.table("acessos_roleta").insert(
        {
            "token": novo_token,
            "utilizado": False,
        }
    ).execute()

    return {"token": novo_token}


@app.get("/premios")
def listar_premios():
    resposta = supabase.table("premios").select("*").execute()
    return {"status": "sucesso", "dados": resposta.data}


@app.get("/verificar-token/{token}")
def verificar_token(token: str, request: Request):
    # Só CONFERE se o link é válido — não marca como usado, não sorteia
    # nada. Serve pra avisar a cliente logo no início (antes de pedir
    # pra ela compartilhar 3 vezes) se o link dela não vai funcionar.
    verificar_limite_de_tentativas(request)

    acesso = supabase.table("acessos_roleta").select("*").eq("token", token).execute()
    if len(acesso.data) == 0:
        return {"valido": False, "mensagem": "Token não existe!"}

    if acesso.data[0]["utilizado"]:
        return {"valido": False, "mensagem": "Esse link já foi utilizado!"}

    return {"valido": True}


@app.post("/sortear/{token}")
def sortear_premio(token: str, dados: ParticipanteInput, request: Request):
    verificar_limite_de_tentativas(request)

    # 1. Verificar se o token existe
    acesso = supabase.table("acessos_roleta").select("*").eq("token", token).execute()
    if len(acesso.data) == 0:
        raise HTTPException(status_code=404, detail="Token não existe!")

    acesso_atual = acesso.data[0]
    if acesso_atual["utilizado"]:
        raise HTTPException(status_code=409, detail="Esse link já foi utilizado!")

    acesso_id = acesso_atual["id"]

    # 2. RESERVAR o token de forma atômica.
    # O ".eq('utilizado', False)" aqui é o que impede que duas
    # pessoas usando o mesmo link ao mesmo tempo consigam sortear
    # duas vezes: só uma das duas requisições vai conseguir
    # atualizar essa linha, a outra recebe 0 resultados.
    reserva = (
        supabase.table("acessos_roleta")
        .update({"utilizado": True})
        .eq("id", acesso_id)
        .eq("utilizado", False)
        .execute()
    )
    if len(reserva.data) == 0:
        raise HTTPException(status_code=409, detail="Esse link já foi utilizado!")

    # 3. Sortear e descontar o estoque, com retentativas.
    # A mesma lógica de "só atualiza se ainda estiver como eu vi"
    # é usada aqui pro estoque, evitando que duas pessoas ganhem
    # a última unidade de um prêmio ao mesmo tempo.
    MAX_TENTATIVAS = 3
    premio_ganho = None

    for _ in range(MAX_TENTATIVAS):
        premios_db = (
            supabase.table("premios").select("*").gt("quantidade_estoque", 0).execute()
        )
        premios = premios_db.data

        if not premios:
            # Devolve o token pro cliente, já que ele não ganhou nada.
            supabase.table("acessos_roleta").update({"utilizado": False}).eq(
                "id", acesso_id
            ).execute()
            raise HTTPException(status_code=409, detail="Acabaram os prêmios no estoque!")

        pesos = [float(p["probabilidade"]) for p in premios]
        candidato = random.choices(premios, weights=pesos, k=1)[0]
        estoque_lido = candidato["quantidade_estoque"]

        atualizacao = (
            supabase.table("premios")
            .update({"quantidade_estoque": estoque_lido - 1})
            .eq("id", candidato["id"])
            .eq("quantidade_estoque", estoque_lido)
            .execute()
        )

        if len(atualizacao.data) > 0:
            premio_ganho = candidato
            break

    if premio_ganho is None:
        # Perdeu a corrida pelo estoque nas 3 tentativas — devolve o token.
        supabase.table("acessos_roleta").update({"utilizado": False}).eq(
            "id", acesso_id
        ).execute()
        raise HTTPException(
            status_code=409,
            detail="Não foi possível concluir o sorteio, tente novamente.",
        )

    premio_id = premio_ganho["id"]

    # 4. Salvar o participante no banco
    participante_inserido = (
        supabase.table("participantes")
        .insert(
            {
                "nome": dados.nome,
                "whatsapp": dados.whatsapp,
                "acesso_id": acesso_id,
                "premio_id": premio_id,
            }
        )
        .execute()
    )

    # Código de conferência do voucher: é o próprio ID salvo na tabela
    # "participantes", formatado de forma mais apresentável. A loja pode
    # conferir esse número diretamente na tabela do Supabase (coluna
    # "id") pra confirmar que o voucher é legítimo.
    participante_id = (
        participante_inserido.data[0]["id"] if participante_inserido.data else None
    )
    codigo_voucher = f"CPR-{participante_id:06d}" if participante_id else "CPR-000000"

    # 5. Descobrir em qual posição da roleta (1 a 12) esse prêmio fica,
    # pra mandar isso pro front-end em vez de fazer ele "adivinhar"
    # comparando textos.
    #
    # ATENÇÃO: isso assume que a ordem dos prêmios na tabela "premios"
    # (por id, do menor pro maior) é a MESMA ordem das 12 fatias
    # cadastradas no JavaScript da roleta. Veja o guia de implementação
    # pra conferir/ajustar isso.
    todos_premios = supabase.table("premios").select("id").order("id").execute()
    ids_em_ordem = [p["id"] for p in todos_premios.data]
    indice_roleta = (
        ids_em_ordem.index(premio_id) + 1 if premio_id in ids_em_ordem else 1
    )

    return {
        "status": "sucesso",
        "mensagem": f"Parabéns {dados.nome}, você ganhou: {premio_ganho['nome']}!",
        "premio": premio_ganho["nome"],
        "indice_roleta": indice_roleta,
        "codigo_voucher": codigo_voucher,
    }
