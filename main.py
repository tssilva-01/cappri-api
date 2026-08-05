import logging
import os
import re
import secrets
from collections import defaultdict, deque
from dataclasses import dataclass
from threading import Lock
from time import monotonic
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator
from supabase import Client, create_client


logger = logging.getLogger("cappri_api")

ORIGEM_OFICIAL = "https://capprimodafeminina.github.io"
TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,32}$")
MENSAGEM_BANCO_INDISPONIVEL = (
    "O serviço está temporariamente indisponível. Tente novamente em instantes."
)


@dataclass(frozen=True)
class Settings:
    """Configurações lidas do ambiente, sem expor os segredos nos logs."""

    supabase_url: str
    supabase_key: str
    senha_funcionaria: str
    origens_permitidas: tuple[str, ...] = (ORIGEM_OFICIAL,)

    @classmethod
    def from_env(cls) -> "Settings":
        valores = {
            "SUPABASE_URL": os.environ.get("SUPABASE_URL", "").strip(),
            "SUPABASE_KEY": os.environ.get("SUPABASE_KEY", "").strip(),
            "SENHA_FUNCIONARIA": os.environ.get("SENHA_FUNCIONARIA", ""),
        }
        ausentes = [nome for nome, valor in valores.items() if not valor]
        if ausentes:
            raise RuntimeError(
                "Variáveis obrigatórias não configuradas: " + ", ".join(ausentes)
            )

        origens_texto = os.environ.get("ORIGENS_PERMITIDAS", ORIGEM_OFICIAL)
        origens = tuple(
            origem.strip().rstrip("/")
            for origem in origens_texto.split(",")
            if origem.strip()
        )
        if not origens:
            raise RuntimeError("Configure ao menos uma origem em ORIGENS_PERMITIDAS.")

        return cls(
            supabase_url=valores["SUPABASE_URL"],
            supabase_key=valores["SUPABASE_KEY"],
            senha_funcionaria=valores["SENHA_FUNCIONARIA"],
            origens_permitidas=origens,
        )


class ParticipanteInput(BaseModel):
    nome: str
    whatsapp: str

    @field_validator("nome")
    @classmethod
    def validar_nome(cls, valor: str) -> str:
        # Também reduz espaços repetidos: "Ana   Silva" vira "Ana Silva".
        valor_normalizado = " ".join(valor.split())
        if len(valor_normalizado) < 2 or len(valor_normalizado) > 100:
            raise ValueError("Digite um nome válido.")
        return valor_normalizado

    @field_validator("whatsapp")
    @classmethod
    def validar_whatsapp(cls, valor: str) -> str:
        somente_numeros = re.sub(r"\D", "", valor)
        if not re.fullmatch(r"\d{10,11}", somente_numeros):
            raise ValueError(
                "WhatsApp inválido. Use o formato (DD) 9XXXX-XXXX, com DDD."
            )
        return somente_numeros


class GerarConviteInput(BaseModel):
    senha: str = Field(min_length=1, max_length=128)


class InMemoryRateLimiter:
    """Proteção simples por IP e por rota para uma única instância da API."""

    def __init__(self, janela_segundos: int = 60) -> None:
        self.janela_segundos = janela_segundos
        self._tentativas: dict[tuple[str, str], deque[float]] = defaultdict(deque)
        self._lock = Lock()

    def verificar(self, request: Request, categoria: str, limite: int) -> None:
        ip = request.client.host if request.client else "desconhecido"
        chave = (categoria, ip)
        agora = monotonic()

        with self._lock:
            tentativas = self._tentativas[chave]
            while tentativas and agora - tentativas[0] >= self.janela_segundos:
                tentativas.popleft()

            if len(tentativas) >= limite:
                raise HTTPException(
                    status_code=429,
                    detail=(
                        "Muitas tentativas em pouco tempo. "
                        "Aguarde um minuto e tente novamente."
                    ),
                )
            tentativas.append(agora)


def validar_formato_token(token: str) -> None:
    # Formatos impossíveis são tratados como token inexistente, sem consultar o banco.
    if not TOKEN_PATTERN.fullmatch(token):
        raise HTTPException(status_code=404, detail="Token não existe!")


def executar_consulta(operacao):
    """Centraliza falhas do Supabase e evita devolver detalhes internos."""

    try:
        return operacao()
    except HTTPException:
        raise
    except Exception:
        logger.exception("Falha em uma operação com o Supabase")
        raise HTTPException(status_code=503, detail=MENSAGEM_BANCO_INDISPONIVEL)


def primeira_linha(resposta: Any) -> dict[str, Any] | None:
    dados = getattr(resposta, "data", None)
    if not dados:
        return None
    return dados[0]


def create_app(
    settings: Settings | None = None,
    database: Client | Any | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    database = database or create_client(settings.supabase_url, settings.supabase_key)

    api = FastAPI(title="Cappri API", version="2.0.0")
    api.state.settings = settings
    api.state.database = database
    api.state.rate_limiter = InMemoryRateLimiter()

    api.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.origens_permitidas),
        allow_credentials=False,
        allow_methods=["GET", "POST"],
        allow_headers=["Content-Type"],
    )

    @api.exception_handler(RequestValidationError)
    async def tratar_erro_de_validacao(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        del request
        erros = exc.errors()
        mensagem = erros[0]["msg"] if erros else "Dados inválidos."
        mensagem = mensagem.replace("Value error, ", "")
        return JSONResponse(status_code=422, content={"detail": mensagem})

    @api.get("/ping")
    def ping() -> dict[str, str]:
        return {"status": "acordado"}

    @api.post("/gerar-convite")
    def gerar_convite(dados: GerarConviteInput, request: Request) -> dict[str, str]:
        api.state.rate_limiter.verificar(request, "gerar-convite", limite=5)

        senha_enviada = dados.senha.encode("utf-8")
        senha_correta = settings.senha_funcionaria.encode("utf-8")
        if not secrets.compare_digest(senha_enviada, senha_correta):
            raise HTTPException(status_code=401, detail="Senha incorreta.")

        novo_token = secrets.token_urlsafe(6)
        executar_consulta(
            lambda: database.table("acessos_roleta")
            .insert({"token": novo_token, "utilizado": False})
            .execute()
        )
        return {"token": novo_token}

    @api.get("/premios")
    def listar_premios() -> dict[str, Any]:
        resposta = executar_consulta(
            lambda: database.table("premios")
            .select("id,nome")
            .order("id")
            .execute()
        )
        return {"status": "sucesso", "dados": resposta.data}

    @api.get("/verificar-token/{token}")
    def verificar_token(token: str, request: Request) -> dict[str, Any]:
        validar_formato_token(token)
        api.state.rate_limiter.verificar(request, "verificar-token", limite=20)

        resposta = executar_consulta(
            lambda: database.table("acessos_roleta")
            .select("utilizado")
            .eq("token", token)
            .limit(1)
            .execute()
        )
        acesso = primeira_linha(resposta)
        if acesso is None:
            return {"valido": False, "mensagem": "Token não existe!"}
        if acesso["utilizado"]:
            return {"valido": False, "mensagem": "Esse link já foi utilizado!"}
        return {"valido": True}

    @api.post("/sortear/{token}")
    def sortear_premio(
        token: str, dados: ParticipanteInput, request: Request
    ) -> dict[str, Any]:
        validar_formato_token(token)
        api.state.rate_limiter.verificar(request, "sortear", limite=5)

        # Uma única RPC executa token, estoque e participante na mesma transação.
        resposta = executar_consulta(
            lambda: database.rpc(
                "sortear_premio_atomico",
                {
                    "p_token": token,
                    "p_nome": dados.nome,
                    "p_whatsapp": dados.whatsapp,
                },
            ).execute()
        )
        resultado = primeira_linha(resposta)
        if resultado is None:
            logger.error("RPC sortear_premio_atomico não devolveu resultado")
            raise HTTPException(status_code=503, detail=MENSAGEM_BANCO_INDISPONIVEL)

        codigo = resultado.get("resultado")
        erros_conhecidos = {
            "token_invalido": (404, "Token não existe!"),
            "token_utilizado": (409, "Esse link já foi utilizado!"),
            "sem_premios": (409, "Acabaram os prêmios no estoque!"),
        }
        if codigo in erros_conhecidos:
            status_code, detalhe = erros_conhecidos[codigo]
            raise HTTPException(status_code=status_code, detail=detalhe)
        if codigo != "sucesso":
            logger.error("RPC sortear_premio_atomico devolveu estado desconhecido")
            raise HTTPException(status_code=503, detail=MENSAGEM_BANCO_INDISPONIVEL)

        participante_id = resultado.get("participante_id")
        if not isinstance(participante_id, int) or participante_id <= 0:
            logger.error("RPC sortear_premio_atomico devolveu participante inválido")
            raise HTTPException(status_code=503, detail=MENSAGEM_BANCO_INDISPONIVEL)

        return {
            "status": "sucesso",
            "mensagem": resultado["mensagem"],
            "premio": resultado["premio"],
            "indice_roleta": resultado["indice_roleta"],
            "codigo_voucher": f"CPR-{participante_id:06d}",
        }

    return api


app = create_app()
