import os
from collections import deque
from dataclasses import dataclass
from typing import Any

import pytest
from fastapi.testclient import TestClient


os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_KEY", "test-key")
os.environ.setdefault("SENHA_FUNCIONARIA", "test-password")

import main  # noqa: E402


@dataclass
class FakeResponse:
    data: list[dict[str, Any]]


class FakeQuery:
    def __init__(self, database: "FakeDatabase", source: str) -> None:
        self.database = database
        self.call: dict[str, Any] = {"source": source, "filters": []}

    def select(self, columns: str) -> "FakeQuery":
        self.call.update(action="select", columns=columns)
        return self

    def insert(self, payload: dict[str, Any]) -> "FakeQuery":
        self.call.update(action="insert", payload=payload)
        return self

    def eq(self, column: str, value: Any) -> "FakeQuery":
        self.call["filters"].append(("eq", column, value))
        return self

    def order(self, column: str) -> "FakeQuery":
        self.call["order"] = column
        return self

    def limit(self, value: int) -> "FakeQuery":
        self.call["limit"] = value
        return self

    def execute(self) -> FakeResponse:
        self.database.calls.append(self.call)
        if not self.database.responses:
            raise AssertionError("O teste não preparou uma resposta para esta consulta.")
        response = self.database.responses.popleft()
        if isinstance(response, Exception):
            raise response
        return FakeResponse(response)


class FakeDatabase:
    def __init__(self, *responses: list[dict[str, Any]] | Exception) -> None:
        self.responses = deque(responses)
        self.calls: list[dict[str, Any]] = []

    def table(self, name: str) -> FakeQuery:
        return FakeQuery(self, f"table:{name}")

    def rpc(self, name: str, params: dict[str, Any]) -> FakeQuery:
        query = FakeQuery(self, f"rpc:{name}")
        query.call.update(action="rpc", params=params)
        return query


@pytest.fixture
def settings() -> main.Settings:
    return main.Settings(
        supabase_url="https://example.supabase.co",
        supabase_key="test-key",
        senha_funcionaria="test-password",
    )


def client_for(settings: main.Settings, database: FakeDatabase) -> TestClient:
    return TestClient(main.create_app(settings=settings, database=database))


def test_ping_nao_consulta_banco(settings: main.Settings) -> None:
    database = FakeDatabase()
    response = client_for(settings, database).get("/ping")

    assert response.status_code == 200
    assert response.json() == {"status": "acordado"}
    assert database.calls == []


def test_cors_aceita_apenas_origem_oficial(settings: main.Settings) -> None:
    client = client_for(settings, FakeDatabase())
    response = client.options(
        "/sortear/abcdefgh",
        headers={
            "Origin": main.ORIGEM_OFICIAL,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
    )

    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == main.ORIGEM_OFICIAL
    assert "access-control-allow-credentials" not in response.headers

    blocked = client.options(
        "/sortear/abcdefgh",
        headers={
            "Origin": "https://site-nao-autorizado.example",
            "Access-Control-Request-Method": "POST",
        },
    )
    assert "access-control-allow-origin" not in blocked.headers


def test_gerar_convite_rejeita_senha_incorreta_sem_consultar_banco(
    settings: main.Settings,
) -> None:
    database = FakeDatabase()
    response = client_for(settings, database).post(
        "/gerar-convite", json={"senha": "errada"}
    )

    assert response.status_code == 401
    assert response.json() == {"detail": "Senha incorreta."}
    assert database.calls == []


def test_gerar_convite_salva_token_seguro(settings: main.Settings) -> None:
    database = FakeDatabase(
        [
            {
                "resultado": "sucesso",
                "token_gerado": "token-devolvido",
                "campanha": "Campanha de testes",
            }
        ]
    )
    response = client_for(settings, database).post(
        "/gerar-convite", json={"senha": "test-password"}
    )

    assert response.status_code == 200
    assert response.json() == {
        "token": "token-devolvido",
        "campanha": "Campanha de testes",
    }
    assert database.calls[0]["source"] == "rpc:gerar_convite_roleta"
    token_enviado = database.calls[0]["params"]["p_token"]
    assert main.TOKEN_PATTERN.fullmatch(token_enviado)
    assert len(token_enviado) == 16


def test_gerar_convite_exige_campanha_ativa(settings: main.Settings) -> None:
    database = FakeDatabase([{"resultado": "sem_campanha"}])
    response = client_for(settings, database).post(
        "/gerar-convite", json={"senha": "test-password"}
    )

    assert response.status_code == 409
    assert response.json() == {"detail": "Não existe uma campanha ativa."}


def test_limite_de_senha_e_separado_por_rota(settings: main.Settings) -> None:
    database = FakeDatabase([{"valido": True, "mensagem": None, "campanha": "Teste"}])
    client = client_for(settings, database)

    for _ in range(5):
        assert client.post("/gerar-convite", json={"senha": "errada"}).status_code == 401

    blocked = client.post("/gerar-convite", json={"senha": "errada"})
    assert blocked.status_code == 429

    # As tentativas de senha não devem bloquear a conferência de um convite.
    verificar = client.get("/verificar-token/abcdefgh")
    assert verificar.status_code == 200
    assert verificar.json() == {"valido": True, "campanha": "Teste"}


def test_verificar_token_invalido_nao_consulta_banco(settings: main.Settings) -> None:
    database = FakeDatabase()
    response = client_for(settings, database).get("/verificar-token/curto")

    assert response.status_code == 404
    assert response.json() == {"detail": "Token não existe!"}
    assert database.calls == []


@pytest.mark.parametrize(
    ("database_result", "expected"),
    [
        (
            [{"valido": False, "mensagem": "Token não existe!", "campanha": None}],
            {"valido": False, "mensagem": "Token não existe!"},
        ),
        (
            [
                {
                    "valido": False,
                    "mensagem": "Esse link já foi utilizado!",
                    "campanha": "Teste",
                }
            ],
            {
                "valido": False,
                "mensagem": "Esse link já foi utilizado!",
                "campanha": "Teste",
            },
        ),
        (
            [{"valido": True, "mensagem": None, "campanha": "Teste"}],
            {"valido": True, "campanha": "Teste"},
        ),
    ],
)
def test_verificar_token(
    settings: main.Settings,
    database_result: list[dict[str, Any]],
    expected: dict[str, Any],
) -> None:
    database = FakeDatabase(database_result)
    response = client_for(settings, database).get("/verificar-token/abcdefgh")

    assert response.status_code == 200
    assert response.json() == expected
    assert database.calls[0] == {
        "source": "rpc:verificar_token_roleta",
        "filters": [],
        "action": "rpc",
        "params": {"p_token": "abcdefgh"},
    }


def test_premios_nao_expoe_estoque_nem_probabilidade(settings: main.Settings) -> None:
    database = FakeDatabase(
        [
            {
                "resultado": "sucesso",
                "mensagem": None,
                "campanha_id": 1,
                "campanha_nome": "Campanha de testes",
                "premio_id": 7,
                "premio_nome": "Brinde",
                "posicao_roleta": 2,
            }
        ]
    )
    response = client_for(settings, database).get("/premios")

    assert response.status_code == 200
    assert response.json() == {
        "status": "sucesso",
        "campanha": {"id": 1, "nome": "Campanha de testes"},
        "dados": [{"id": 7, "nome": "Brinde", "posicao_roleta": 2}],
    }
    assert "estoque_disponivel" not in response.text
    assert "peso_sorteio" not in response.text
    assert database.calls[0]["source"] == "rpc:listar_premios_roleta"


def test_premios_exige_campanha_ativa(settings: main.Settings) -> None:
    database = FakeDatabase([{"resultado": "sem_campanha"}])
    response = client_for(settings, database).get("/premios")

    assert response.status_code == 409
    assert response.json() == {"detail": "Não existe uma campanha ativa."}


def test_sortear_normaliza_dados_e_usa_uma_unica_rpc(settings: main.Settings) -> None:
    database = FakeDatabase(
        [
            {
                "resultado": "sucesso",
                "mensagem": "Parabéns Ana Silva, você ganhou: Brinde!",
                "premio": "Brinde",
                "indice_roleta": 3,
                "participante_id": 42,
            }
        ]
    )
    response = client_for(settings, database).post(
        "/sortear/abcdefgh",
        json={
            "nome": "  Ana   Silva  ",
            "whatsapp": "(11) 99999-9999",
            "consentimento": True,
        },
    )

    assert response.status_code == 200
    assert response.json() == {
        "status": "sucesso",
        "mensagem": "Parabéns Ana Silva, você ganhou: Brinde!",
        "premio": "Brinde",
        "indice_roleta": 3,
        "codigo_voucher": "CPR-000042",
    }
    assert len(database.calls) == 1
    assert database.calls[0] == {
        "source": "rpc:sortear_premio_atomico",
        "filters": [],
        "action": "rpc",
        "params": {
            "p_token": "abcdefgh",
            "p_nome": "Ana Silva",
            "p_whatsapp": "11999999999",
            "p_consentimento": True,
        },
    }


@pytest.mark.parametrize(
    ("codigo", "status_code", "detail"),
    [
        ("token_invalido", 404, "Token não existe!"),
        ("token_utilizado", 409, "Esse link já foi utilizado!"),
        ("campanha_inativa", 409, "Esta campanha não está ativa."),
        ("sem_premios", 409, "Acabaram os prêmios no estoque!"),
    ],
)
def test_sortear_traduz_resultados_conhecidos(
    settings: main.Settings, codigo: str, status_code: int, detail: str
) -> None:
    database = FakeDatabase([{"resultado": codigo}])
    response = client_for(settings, database).post(
        "/sortear/abcdefgh",
        json={"nome": "Ana", "whatsapp": "11999999999", "consentimento": True},
    )

    assert response.status_code == status_code
    assert response.json() == {"detail": detail}


def test_validacao_impede_rpc_com_dados_invalidos(settings: main.Settings) -> None:
    database = FakeDatabase()
    response = client_for(settings, database).post(
        "/sortear/abcdefgh",
        json={"nome": "A", "whatsapp": "123", "consentimento": True},
    )

    assert response.status_code == 422
    assert response.json() == {"detail": "Digite um nome válido."}
    assert database.calls == []


def test_validacao_exige_consentimento(settings: main.Settings) -> None:
    database = FakeDatabase()
    response = client_for(settings, database).post(
        "/sortear/abcdefgh",
        json={"nome": "Ana", "whatsapp": "11999999999", "consentimento": False},
    )

    assert response.status_code == 422
    assert response.json() == {
        "detail": "Você precisa aceitar o contato para participar."
    }
    assert database.calls == []


def test_falha_do_banco_retorna_erro_generico(settings: main.Settings) -> None:
    database = FakeDatabase(RuntimeError("segredo interno do banco"))
    response = client_for(settings, database).get("/premios")

    assert response.status_code == 503
    assert response.json() == {"detail": main.MENSAGEM_BANCO_INDISPONIVEL}
    assert "segredo interno" not in response.text


def test_configuracao_exige_todas_as_variaveis(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SUPABASE_KEY", raising=False)

    with pytest.raises(RuntimeError, match="SUPABASE_KEY"):
        main.Settings.from_env()
