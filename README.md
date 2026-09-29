# Convite Capelasso & Anne — 19 anos

Convite digital com confirmação, moderação pelo Telegram e painel admin.
**Só 4 arquivos que importam:** `index.html` (convite + painel em `/admin`), `supabase/setup.sql` (banco inteiro), `supabase/functions/telegram/index.ts` (bot) e `vercel.json`.

## 1. Banco (Supabase)
1. Crie um projeto em supabase.com.
2. Abra `supabase/setup.sql`, troque `<REF>` (código do projeto, ex.: `abcd1234`) e o `TROQUE-POR-UM-SEGREDO-LONGO` no bloco final, e rode no **SQL Editor**.
3. **Authentication → Users → Add user** (seu e-mail/senha). Em Sign In / Providers, desative "Allow new users to sign up".
4. No SQL Editor: `insert into admin_users select id from auth.users where email='SEU@EMAIL.COM';`
5. Cadastre convidados no painel `/admin` (ou: `insert into guests(name) values ('João Silva');`).

## 2. Configurar o site
No topo do `index.html` (bloco `window.CFG`) coloque **Project URL** e **anon public key** (Project Settings → API). A anon key é pública e pode ir para o GitHub; **nunca use a `service_role` aqui**. Nomes, idade, local e data do convite também ficam nesse bloco (data/local podem ser mudados em `/admin` → Evento).

## 3. Bot do Telegram
1. **@BotFather** → `/newbot` → guarde o token. Cada admin abre o bot e manda `/start`; o ID numérico de cada um vem do **@userinfobot**.
2. `cp supabase/.env.example supabase/.env` e preencha (`NOTIFY_SECRET` = o mesmo segredo que você pôs no `setup.sql`).
3. No terminal:
```
supabase login && supabase link --project-ref <REF>
supabase secrets set --env-file supabase/.env
supabase functions deploy telegram --no-verify-jwt
curl "https://api.telegram.org/bot<TOKEN>/setWebhook" \
  -d url="https://<REF>.supabase.co/functions/v1/telegram" \
  -d secret_token="<TELEGRAM_WEBHOOK_SECRET>" -d allowed_updates='["callback_query"]'
```
4. Teste: confirme presença com um convidado; a mensagem com **✅ CONFIRMAR / ❌ NEGAR** chega no Telegram.

## 4. GitHub + Vercel
```
git init && git add . && git commit -m "convite" && git branch -M main
git remote add origin https://github.com/SEU-USUARIO/convite19.git && git push -u origin main
```
Na Vercel: **Add New → Project → importe o repositório → Deploy** (sem build, sem variáveis). Seu link: `https://<projeto>.vercel.app` e painel em `/admin`.
O `.gitignore` já protege `supabase/.env`.

## Uso
- **Aprovar/negar:** pelo Telegram (ou em `/admin` → Moderação, útil para desfazer).
- **Excluir spam:** "Excluir confirmação" ou "Remover convidado" no painel; tudo fica no histórico.
- **Cores:** variáveis `:root` no topo do `<style>` do `index.html`.

## Segurança (resumo)
Visitantes só executam 3 funções do banco (verificar, confirmar, listar aprovados) com limite de 10 tentativas/10 min por IP; status é definido no servidor; RLS bloqueia acesso direto às tabelas; o token do bot só existe nos secrets do Supabase; só os IDs em `TELEGRAM_ADMIN_CHAT_IDS` aprovam/negam; a decisão só vale enquanto o status é `pending`.
