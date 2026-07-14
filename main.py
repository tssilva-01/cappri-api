from fastapi import FastAPI
from supabase import create_client, Client
import random

# 1. Configurando a conexão
url: str = "https://ahbfzljivifqxzwcynbe.supabase.co"
key: str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFoYmZ6bGppdmlmcXh6d2N5bmJlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM4NjkyNjMsImV4cCI6MjA5OTQ0NTI2M30.Ya71-XTbnRJL18jgJ7fyap0fRC0ijpYj9oAOyE2rFts"
supabase: Client = create_client(url, key)

app = FastAPI()

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware # Adicione esta linha lá em cima com as outras importações
from supabase import create_client, Client
import random

# ... suas configurações do supabase (url e key) ...

app = FastAPI()

# --- ADICIONE ESTE BLOCO AQUI ---
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # Permite que qualquer site acesse (ideal para testarmos agora)
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
# -------------------------------

# Rota antiga (só para listar)
@app.get("/premios")
def listar_premios():
    resposta = supabase.table("premios").select("*").execute()
    return {"status": "sucesso", "dados": resposta.data}

# NOVA ROTA: O Sorteio Oficial
@app.post("/sortear/{token}")
def sortear_premio(token: str, nome_cliente: str, whatsapp_cliente: str):
    
    # 1. Verificar se o token é válido
    acesso = supabase.table("acessos_roleta").select("*").eq("token", token).execute()
    
    if len(acesso.data) == 0:
        return {"erro": "Token não existe!"}
        
    if acesso.data[0]['utilizado'] == True:
        return {"erro": "Esse link já foi utilizado!"}
        
    acesso_id = acesso.data[0]['id']

    # 2. Pegar apenas prêmios que ainda têm estoque
    premios_db = supabase.table("premios").select("*").gt("quantidade_estoque", 0).execute()
    premios = premios_db.data
    
    if not premios:
        return {"erro": "Acabaram os prêmios no estoque!"}

    # 3. Sorteio Matemático baseado na probabilidade
    pesos = [float(p['probabilidade']) for p in premios]
    premio_ganho = random.choices(premios, weights=pesos, k=1)[0]
    premio_id = premio_ganho['id']

    # 4. Salvar o participante no banco
    supabase.table("participantes").insert({
        "nome": nome_cliente,
        "whatsapp": whatsapp_cliente,
        "acesso_id": acesso_id,
        "premio_id": premio_id
    }).execute()

    # 5. Atualizar o token como utilizado e descontar o estoque
    supabase.table("acessos_roleta").update({"utilizado": True}).eq("id", acesso_id).execute()
    
    novo_estoque = premio_ganho['quantidade_estoque'] - 1
    supabase.table("premios").update({"quantidade_estoque": novo_estoque}).eq("id", premio_id).execute()

    # Retorna o resultado para o visual (Frontend) mostrar na tela
    return {
        "status": "sucesso", 
        "mensagem": f"Parabéns {nome_cliente}, você ganhou: {premio_ganho['nome']}!",
        "premio": premio_ganho['nome']
    }